// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (token/ERC20/extensions/ERC20Snapshot.sol)

pragma solidity ^0.8.0;

import "./ERC20.sol";
import "./Arrays.sol";
import "./Counters.sol";

/**
 * @dev This contract extends an ERC20 token with a snapshot mechanism. When a snapshot is created, the balances and
 * total supply at the time are recorded for later access.
 *
 * This can be used to safely create mechanisms based on token balances such as trustless dividends or weighted voting.
 * In naive implementations it's possible to perform a "double spend" attack by reusing the same balance from different
 * accounts. By using snapshots to calculate dividends or voting power, those attacks no longer apply. It can also be
 * used to create an efficient ERC20 forking mechanism.
 *
 * Snapshots are created by the internal {_snapshot} function, which will emit the {Snapshot} event and return a
 * snapshot id. To get the total supply at the time of a snapshot, call the function {totalSupplyAt} with the snapshot
 * id. To get the balance of an account at the time of a snapshot, call the {balanceOfAt} function with the snapshot id
 * and the account address.
 *
 * NOTE: Snapshot policy can be customized by overriding the {_getCurrentSnapshotId} method. For example, having it
 * return `block.number` will trigger the creation of snapshot at the beginning of each new block. When overriding this
 * function, be careful about the monotonicity of its result. Non-monotonic snapshot ids will break the contract.
 *
 * Implementing snapshots for every block using this method will incur significant gas costs. For a gas-efficient
 * alternative consider {ERC20Votes}.
 *
 * ==== Gas Costs
 *
 * Snapshots are efficient. Snapshot creation is _O(1)_. Retrieval of balances or total supply from a snapshot is _O(log
 * n)_ in the number of snapshots that have been created, although _n_ for a specific account will generally be much
 * smaller since identical balances in subsequent snapshots are stored as a single entry.
 *
 * There is a constant overhead for normal ERC20 transfers due to the additional snapshot bookkeeping. This overhead is
 * only significant for the first transfer that immediately follows a snapshot for a particular account. Subsequent
 * transfers will have normal cost until the next snapshot, and so on.
 */

abstract contract ERC20Snapshot is ERC20 {
    // Inspired by Jordi Baylina's MiniMeToken to record historical balances:
    // https://github.com/Giveth/minime/blob/ea04d950eea153a04c51fa510b068b9dded390cb/contracts/MiniMeToken.sol

    using Arrays for uint256[];
    using Counters for Counters.Counter;

    // Snapshotted values have arrays of ids and the value corresponding to that id. These could be an array of a
    // Snapshot struct, but that would impede usage of functions that work on an array.
    struct Snapshots {
        uint256[] ids;
        uint256[] values;
    }

    mapping(address => Snapshots) private _accountBalanceSnapshots;
    Snapshots private _totalSupplySnapshots;

    // Snapshot ids increase monotonically, with the first value being 1. An id of 0 is invalid.
    Counters.Counter private _currentSnapshotId;

    /**
     * @dev Emitted by {_snapshot} when a snapshot identified by `id` is created.
     */
    event Snapshot(uint256 id);

    function _snapshot() internal virtual returns (uint256) {
        _currentSnapshotId.increment();

        uint256 currentId = _getCurrentSnapshotId();
        emit Snapshot(currentId);
        return currentId;
    }

    /**
     * @dev Get the current snapshotId
     */
    function _getCurrentSnapshotId() internal view virtual returns (uint256) {
        return _currentSnapshotId.current();
    }

    /**
     * @dev Retrieves the balance of `account` at the time `snapshotId` was created.
     */
    function balanceOfAt(address account, uint256 snapshotId) public view virtual returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(snapshotId, _accountBalanceSnapshots[account]);

        return snapshotted ? value : balanceOf(account);
    }

    /**
     * @dev Retrieves the total supply at the time `snapshotId` was created.
     */
    function totalSupplyAt(uint256 snapshotId) public view virtual returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(snapshotId, _totalSupplySnapshots);

        return snapshotted ? value : totalSupply();
    }

    // Update balance and/or total supply snapshots before the values are modified. This is implemented
    // in the _beforeTokenTransfer hook, which is executed for _mint, _burn, and _transfer operations.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);

        if (from == address(0)) {
            // mint
            _updateAccountSnapshot(to);
            _updateTotalSupplySnapshot();
        } else if (to == address(0)) {
            // burn
            _updateAccountSnapshot(from);
            _updateTotalSupplySnapshot();
        } else {
            // transfer
            _updateAccountSnapshot(from);
            _updateAccountSnapshot(to);
        }
    }

    function _valueAt(uint256 snapshotId, Snapshots storage snapshots) private view returns (bool, uint256) {
        require(snapshotId > 0, "ERC20Snapshot: id is 0");
        require(snapshotId <= _getCurrentSnapshotId(), "ERC20Snapshot: nonexistent id");

        // When a valid snapshot is queried, there are three possibilities:
        //  a) The queried value was not modified after the snapshot was taken. Therefore, a snapshot entry was never
        //  created for this id, and all stored snapshot ids are smaller than the requested one. The value that corresponds
        //  to this id is the current one.
        //  b) The queried value was modified after the snapshot was taken. Therefore, there will be an entry with the
        //  requested id, and its value is the one to return.
        //  c) More snapshots were created after the requested one, and the queried value was later modified. There will be
        //  no entry for the requested id: the value that corresponds to it is that of the smallest snapshot id that is
        //  larger than the requested one.
        
        // In summary, we need to find an element in an array, returning the index of the smallest value that is larger if
        // it is not found, unless said value doesn't exist (e.g. when all values are smaller). Arrays.findUpperBound does
        // exactly this.
             //////////////////
        // 1) не было токенов и после snapshot тоже
        //     ids []      values []           snapshots.ids.length = 0 (записей нет)

        // 2) не было токенов, перед snapshot появились (_mint or _fransfer)
        //    2.1) момент транзакции(mint +100 NTTT): ids []      values []     snapshots.ids.length = 0. (перед snapshot записей нет)
        //    2.2) момент snapshot - 1    ((как тогда узнать баланс, если не было записей???))
        //    2.3) запрос баланса в snapshot - 1   (balanceOf(account); = 100)

        // а что если совершится перевод, значит текущий баланс изменится... что покажет snapshot - 1 ?
        //  уже   currentId = 1
        //    2.4) момент транзакции(-30 NTTT): (from) ids [0: 1]    values [0: 100]     snapshots.ids.length = 1
        //       (from = 70, to = 30)           (to)   ids [0: 1]    values [0: 0]     snapshots.ids.length = 1.
        //    2.5) запрос баланса(from) в snapshot - 1.  (value: 100) 

        //  совершается второй перевод, значит добавится ещё запись в массив... что покажет snapshot - 1 ?
        //    2.6) момент транзакции(-25 NTTT): (from) ids [0: 1]    values [0: 100]     snapshots.ids.length = 1
        //        (from = 45, to = 55)          (to)   ids [0: 1]    values [0: 0]       snapshots.ids.length = 1.
        //                                                                                новых записей нет, пока не совершится следующий snapshot
        //    2.7) запрос баланса(from) в snapshot - 1.  (value: 100)
        //
        //    2.8) момент snapshot - 2 
        //  уже   currentId = 2
        //    2.9.1) запрос баланса(from) в snapshot - 2.  (balanceOf(account): 45) 
        //    2.9.2) запрос баланса(to) в snapshot - 2.  (balanceOf(account): 55) 
        //
        //    2.10) момент транзакции(-15 NTTT): (from) ids [0: 1,    values [0: 100,     
        //                (from = 35).                       1: 2]    values  1: 45]     snapshots.ids.length = 2
        //                                       (to)   ids [0: 1]    values [0: 0,       
        //                                                   1: 2]    values  1: 55]     snapshots.ids.length = 2
        //    2.11) запрос баланса(to) в snapshot - 1.  (value: 0)

        // ИТОГ:  новых записей нет, пока не совершится следующий snapshot, 
        // После совершения snapshot каждая первая транзакция добавляет в массив новое значение value 
        // равное количеству монет перед транзакцией, по причине выполнения вспомогательной ф-ции _beforeTokenTransfer()
        // При отсутсвии движения в адресе и наличии нескольких последующих snapshots, 
        // существующая последняя запись валидна для своего snapshot(после которого была сделана)
        // для последующих берется просто текущий баланс


        uint256 index = snapshots.ids.findUpperBound(snapshotId);
        // 1) index = возврат индекса найденного элемента   0: 1
        // 2) index = если элемент больше, чем есть их в массиве 
        //  возвращается первый индекс после последнего элемента
        // index = 1 при snapshotId = 2 и snapshots.ids.length = 1

        if (index == snapshots.ids.length) {
            return (false, 0);
        } else {
            return (true, snapshots.values[index]);
        }
    }

    function _updateAccountSnapshot(address account) private {
        _updateSnapshot(_accountBalanceSnapshots[account], balanceOf(account));
    }

    function _updateTotalSupplySnapshot() private {
        _updateSnapshot(_totalSupplySnapshots, totalSupply());
    }

    function _updateSnapshot(Snapshots storage snapshots, uint256 currentValue) private {
        uint256 currentId = _getCurrentSnapshotId();
        if (_lastSnapshotId(snapshots.ids) < currentId) {
            snapshots.ids.push(currentId);
            snapshots.values.push(currentValue);
        }
    }

    function _lastSnapshotId(uint256[] storage ids) private view returns (uint256) {
        if (ids.length == 0) {
            return 0;
        } else {
            return ids[ids.length - 1];   // [1-1] return 1
        }
    }
}