// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

// import "forge-std/console.sol";

contract L1SharedBridgeTest is Test {
    event BridgehubDepositBaseTokenInitiated(
        uint256 indexed chainId,
        address indexed from,
        address l1Token,
        uint256 amount
    );

    event BridgehubDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        address indexed from,
        address to,
        address l1Token,
        uint256 amount
    );

    event BridgehubDepositFinalized(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        bytes32 indexed l2DepositTxHash
    );

    event WithdrawalFinalizedSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        address indexed l1Token,
        uint256 amount
    );

    event ClaimedFailedDepositSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        address indexed l1Token,
        uint256 amount
    );

    event LegacyDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address to,
        address l1Token,
        uint256 amount
    );

    L1SharedBridge sharedBridgeImpl;
    L1SharedBridge sharedBridge;
    address bridgehubAddress;
    address l1ERC20BridgeAddress;
    address l2SharedBridge;
    TestnetERC20Token token;
    uint256 eraFirstPostUpgradeBatch;

    address owner;
    address admin;
    address zkSync;
    address alice;
    address bob;
    uint256 chainId;
    uint256 amount = 100;
    bytes32 txHash;

    uint256 eraChainId;
    address eraDiamondProxy;

    uint256 l2BatchNumber;
    uint256 l2MessageIndex;
    uint16 l2TxNumberInBatch;
    bytes32[] merkleProof;

    // storing depositHappened[chainId][l2TxHash] = txDataHash. DepositHappened is 4th so 4 -1 + dependency storage slots
    uint256 depositLocationInStorage = uint256(4 - 1 + 1 + 1);
    uint256 chainBalanceLocationInStorage = uint256(7 - 1 + 1 + 1);

    function setUp() public {
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        // zkSync = makeAddr("zkSync");
        bridgehubAddress = makeAddr("bridgehub");
        alice = makeAddr("alice");
        // bob = makeAddr("bob");
        address l1WethAddress = makeAddr("weth");
        l1ERC20BridgeAddress = makeAddr("l1ERC20Bridge");
        l2SharedBridge = makeAddr("l2SharedBridge");

        txHash = bytes32(uint256(uint160(makeAddr("txHash"))));
        l2BatchNumber = uint256(uint160(makeAddr("l2BatchNumber")));
        l2MessageIndex = uint256(uint160(makeAddr("l2MessageIndex")));
        l2TxNumberInBatch = uint16(uint160(makeAddr("l2TxNumberInBatch")));
        merkleProof = new bytes32[](1);
        eraFirstPostUpgradeBatch = 1;

        chainId = 1;
        eraChainId = 9;
        eraDiamondProxy = makeAddr("eraDiamondProxy");

        token = new TestnetERC20Token("TestnetERC20Token", "TET", 18);
        sharedBridgeImpl = new L1SharedBridge({
            _l1WethAddress: l1WethAddress,
            _bridgehub: IBridgehub(bridgehubAddress),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });
        TransparentUpgradeableProxy sharedBridgeProxy = new TransparentUpgradeableProxy(
            address(sharedBridgeImpl),
            admin,
            abi.encodeWithSelector(L1SharedBridge.initialize.selector, owner, eraFirstPostUpgradeBatch)
        );
        sharedBridge = L1SharedBridge(payable(sharedBridgeProxy));
        vm.prank(owner);
        sharedBridge.setL1Erc20Bridge(l1ERC20BridgeAddress);
        vm.prank(owner);
        sharedBridge.initializeChainGovernance(chainId, l2SharedBridge);
        vm.prank(owner);
        sharedBridge.initializeChainGovernance(eraChainId, l2SharedBridge);
    }

    function test_bridgehubDepositBaseToken_Eth() public {
        vm.deal(bridgehubAddress, amount);
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositBaseTokenInitiated(chainId, alice, ETH_TOKEN_ADDRESS, amount);
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, alice, ETH_TOKEN_ADDRESS, amount);
    }

    function test_bridgehubDepositBaseToken_Erc() public {
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositBaseTokenInitiated(chainId, alice, address(token), amount);
        sharedBridge.bridgehubDepositBaseToken(chainId, alice, address(token), amount);
    }

    function test_bridgehubDeposit_Eth() public {
        vm.deal(bridgehubAddress, amount);
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositInitiated({
            chainId: chainId,
            txDataHash: txDataHash,
            from: alice,
            to: zkSync,
            l1Token: ETH_TOKEN_ADDRESS,
            amount: amount
        });
        sharedBridge.bridgehubDeposit{value: amount}(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, 0, bob));
    }

    function test_bridgehubDeposit_Erc() public {
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        emit BridgehubDepositInitiated({
            chainId: chainId,
            txDataHash: txDataHash,
            from: alice,
            to: zkSync,
            l1Token: address(token),
            amount: amount
        });
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubConfirmL2Transaction() public {
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        emit BridgehubDepositFinalized(chainId, txDataHash, txHash);
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
    }

    function test_claimFailedDeposit_Erc() public {
        token.mint(address(sharedBridge), amount);
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        vm.store(
            address(sharedBridge),
            keccak256(abi.encode(txHash, keccak256(abi.encode(chainId, depositLocationInStorage)))),
            txDataHash
        );
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(address(token))),
                    keccak256(abi.encode(chainId, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                chainId,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit ClaimedFailedDepositSharedBridge({chainId: chainId, to: alice, l1Token: address(token), amount: amount});
        sharedBridge.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Token: address(token),
            _amount: amount,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }

    function test_claimFailedDeposit_Eth() public {
        vm.deal(address(sharedBridge), amount);

        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        vm.store(
            address(sharedBridge),
            keccak256(abi.encode(txHash, keccak256(abi.encode(chainId, depositLocationInStorage)))),
            txDataHash
        );
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(ETH_TOKEN_ADDRESS)),
                    keccak256(abi.encode(chainId, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                chainId,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit ClaimedFailedDepositSharedBridge({
            chainId: chainId,
            to: alice,
            l1Token: ETH_TOKEN_ADDRESS,
            amount: amount
        });
        sharedBridge.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Token: ETH_TOKEN_ADDRESS,
            _amount: amount,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth() public {
        vm.deal(address(sharedBridge), amount);

        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(ETH_TOKEN_ADDRESS)),
                    keccak256(abi.encode(chainId, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector, alice, amount);
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, ETH_TOKEN_ADDRESS, amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_ErcOnEth() public {
        token.mint(address(sharedBridge), amount);

        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(address(token))),
                    keccak256(abi.encode(chainId, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: l2SharedBridge,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, address(token), amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnErc() public {
        vm.deal(address(sharedBridge), amount);

        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(ETH_TOKEN_ADDRESS)),
                    keccak256(abi.encode(chainId, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            ETH_TOKEN_ADDRESS,
            amount
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: l2SharedBridge,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, ETH_TOKEN_ADDRESS, amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_BaseErcOnErc() public {
        token.mint(address(sharedBridge), amount);

        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(address(token))),
                    keccak256(abi.encode(chainId, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, address(token), amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_NonBaseErcOnErc() public {
        token.mint(address(sharedBridge), amount);

        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(address(token))),
                    keccak256(abi.encode(chainId, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        vm.mockCall(bridgehubAddress, abi.encodeWithSelector(IBridgehub.baseToken.selector), abi.encode(address(2))); //alt base token
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: l2SharedBridge,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, address(token), amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth_LegacyTx() public {
        vm.deal(address(sharedBridge), amount);
        uint256 legacyBatchNumber = 0;

        vm.mockCall(
            l1ERC20BridgeAddress,
            abi.encodeWithSelector(IL1ERC20Bridge.isWithdrawalFinalized.selector),
            abi.encode(false)
        );

        vm.mockCall(
            eraDiamondProxy,
            abi.encodeWithSelector(IGetters.isEthWithdrawalFinalized.selector),
            abi.encode(false)
        );

        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(ETH_TOKEN_ADDRESS)),
                    keccak256(abi.encode(eraChainId, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector, alice, amount);
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                eraChainId,
                legacyBatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(eraChainId, alice, ETH_TOKEN_ADDRESS, amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: legacyBatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }
}
