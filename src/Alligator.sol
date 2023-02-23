// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IGovernorBravo} from "./interfaces/IGovernorBravo.sol";
import {INounsDAOV2} from "./interfaces/INounsDAOV2.sol";
import {IRule} from "./interfaces/IRule.sol";
import {ENSHelper} from "./ENSHelper.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

struct Rules {
    uint8 permissions;
    uint8 maxRedelegations;
    uint32 notValidBefore;
    uint32 notValidAfter;
    uint16 blocksBeforeVoteCloses;
    address customRule;
}
// packed Rules nice

// fractional delegations probably doable with an updated governor contract bc of this! ie call castVote(proposalId, support, numVotes) and can assign voter count by subdelegate
contract Proxy is IERC1271 {
    address internal immutable owner;
    address internal immutable governor;

    // every token holder deploys their own proxy, per governor
    // only callable by alligator

    // Maybe we actually want 1 Alligator for any governor. This could allow sharing rules potentially? Not w current design tho bc its rules per delegatee
    // Would be cool to think about how you can share rules though.
    // Could have subDelegations be per proxy address then.

    // IE I want to use Alligator and establish a set of rules for all the DAOs and all delegatees I want to govern?

    // deploy own proxy is a bit of a hurdle?
    constructor(address _governor) {
        owner = msg.sender;
        governor = _governor;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) public view override returns (bytes4 magicValue) {
        return Alligator(payable(owner)).isValidProxySignature(address(this), hash, signature);
    }

    function setENSReverseRecord(string calldata name) external {
        require(msg.sender == owner);
        IENSReverseRegistrar(0x084b1c3C81545d370f3634392De611CaaBFf8148).setName(name);
    }

    fallback() external payable {
        // default calls the governor contract
        require(msg.sender == owner);
        address addr = governor;

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := call(gas(), addr, callvalue(), 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {
        revert();
    }
}

contract Alligator is ENSHelper {
    INounsDAOV2 public immutable governor;

    // From => To => Rules

    // could update this with named mappings in 0.8.18 to make this a little more readable
    // mapping (address from => mapping (address to => Rules rule))
    mapping(address => mapping(address => Rules)) public subDelegations;
    mapping(address => mapping(bytes32 => bool)) internal validSignatures;

    uint8 internal constant PERMISSION_VOTE = 0x01;
    uint8 internal constant PERMISSION_SIGN = 0x02;
    uint8 internal constant PERMISSION_PROPOSE = 0x04;
    // potential to add new permission "types" depending on gov contract actions

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    bytes32 internal constant BALLOT_TYPEHASH = keccak256("Ballot(uint256 proposalId,uint8 support)");

    /// @notice The maximum priority fee used to cap gas refunds in `castRefundableVote`
    uint256 public constant MAX_REFUND_PRIORITY_FEE = 2 gwei;

    /// @notice The vote refund gas overhead, including 7K for ETH transfer and 29K for general transaction overhead
    uint256 public constant REFUND_BASE_GAS = 36000;

    /// @notice The maximum gas units the DAO will refund voters on; supports about 9,190 characters
    uint256 public constant MAX_REFUND_GAS_USED = 200_000;

    /// @notice The maximum basefee the DAO will refund voters on
    uint256 public constant MAX_REFUND_BASE_FEE = 200 gwei;

    event ProxyDeployed(address indexed owner, address proxy);
    event SubDelegation(address indexed from, address indexed to, Rules rules);
    event VoteCast(
        address indexed proxy, address indexed voter, address[] authority, uint256 proposalId, uint8 support
    );
    event Signed(address indexed proxy, address[] authority, bytes32 messageHash);
    event RefundableVote(address indexed voter, uint256 refundAmount, bool refundSent);

    error BadSignature();
    error NotDelegated(address from, address to, uint8 requiredPermissions);
    error TooManyRedelegations(address from, address to);
    error NotValidYet(address from, address to, uint32 willBeValidFrom);
    error NotValidAnymore(address from, address to, uint32 wasValidUntil);
    error TooEarly(address from, address to, uint32 blocksBeforeVoteCloses);
    error InvalidCustomRule(address from, address to, address customRule);

    constructor(INounsDAOV2 _governor, string memory _ensName, bytes32 _ensNameHash)
        ENSHelper(_ensName, _ensNameHash)
    {
        governor = _governor;
    }

    function create(address owner) public returns (address endpoint) {
        // proxy address determinitic by token owner
        bytes32 salt = bytes32(uint256(uint160(owner)));
        endpoint = address(new Proxy{salt: salt}(address(governor)));
        emit ProxyDeployed(owner, endpoint);

        if (ensNameHash != 0) {
            string memory reverseName = registerDeployment(endpoint);
            Proxy(payable(endpoint)).setENSReverseRecord(reverseName);
        }
    }

    function proxyAddress(address owner) public view returns (address endpoint) {
        bytes32 salt = bytes32(uint256(uint160(owner)));
        endpoint = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            keccak256(abi.encodePacked(type(Proxy).creationCode, abi.encode(address(governor))))
                        )
                    )
                )
            )
        );
    }

    function propose(
        address[] calldata authority,
        address[] calldata targets,
        uint256[] calldata values,
        string[] calldata signatures,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256 proposalId) {
        address proxy = proxyAddress(authority[0]);
        // Create a proposal first so the custom rules can validate it
        proposalId = INounsDAOV2(proxy).propose(targets, values, signatures, calldatas, description);
        validate(msg.sender, authority, PERMISSION_PROPOSE, proposalId, 0xFF);
    }

    function castVote(address[] calldata authority, uint256 proposalId, uint8 support) external {
        validate(msg.sender, authority, PERMISSION_VOTE, proposalId, support);

        address proxy = proxyAddress(authority[0]);
        INounsDAOV2(proxy).castVote(proposalId, support);
        emit VoteCast(proxy, msg.sender, authority, proposalId, support);
    }

    function castVoteWithReason(address[] calldata authority, uint256 proposalId, uint8 support, string calldata reason)
        public
    {
        validate(msg.sender, authority, PERMISSION_VOTE, proposalId, support);

        address proxy = proxyAddress(authority[0]);
        INounsDAOV2(proxy).castVoteWithReason(proposalId, support, reason);
        emit VoteCast(proxy, msg.sender, authority, proposalId, support);
    }

    function castVotesWithReasonBatched(
        address[][] calldata authorities,
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) public {
        for (uint256 i = 0; i < authorities.length; i++) {
            castVoteWithReason(authorities[i], proposalId, support, reason);
        }
    }

    function castRefundableVotesWithReasonBatched(
        address[][] calldata authorities,
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) external {
        uint256 startGas = gasleft();
        castVotesWithReasonBatched(authorities, proposalId, support, reason);
        // TODO: Make sure the method call above actually resulted in new votes casted, otherwise
        // the refund mechanism can be abused to drain the Alligator's funds
        _refundGas(startGas);
    }

    function castVoteBySig(
        address[] calldata authority,
        uint256 proposalId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        // might be nice to move to a lib to handle signing & typehashes
        // OZ has a nice lib for handling domain seperator hashes that caches this and only updates in case chainId changes
        // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/cryptography/EIP712.sol
        bytes32 domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Alligator"), block.chainid, address(this)));
        bytes32 structHash = keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);

        if (signatory == address(0)) {
            revert BadSignature();
        }

        validate(signatory, authority, PERMISSION_VOTE, proposalId, support);

        address proxy = proxyAddress(authority[0]);
        INounsDAOV2(proxy).castVote(proposalId, support);
        emit VoteCast(proxy, signatory, authority, proposalId, support);
    }

    function sign(address[] calldata authority, bytes32 hash) external {
        validate(msg.sender, authority, PERMISSION_SIGN, 0, 0xFE);

        address proxy = proxyAddress(authority[0]);
        validSignatures[proxy][hash] = true;
        emit Signed(proxy, authority, hash);
    }

    function isValidProxySignature(address proxy, bytes32 hash, bytes calldata data)
        public
        view
        returns (bytes4 magicValue)
    {
        if (data.length > 0) {
            (address[] memory authority, bytes memory signature) = abi.decode(data, (address[], bytes));
            address signer = ECDSA.recover(hash, signature);
            validate(signer, authority, PERMISSION_SIGN, 0, 0xFE);
            return IERC1271.isValidSignature.selector;
        }
        return validSignatures[proxy][hash] ? IERC1271.isValidSignature.selector : bytes4(0);
    }

    // could be nice to add a subDelegateBySig
    // would allow submission of the delegation to be submitted by the delegatee (ie gas fees paid by delegatee)
    function subDelegate(address to, Rules calldata rules) external {
        address proxy = proxyAddress(msg.sender);
        if (proxy.code.length == 0) {
            create(msg.sender);
        }

        subDelegations[msg.sender][to] = rules;
        emit SubDelegation(msg.sender, to, rules);
    }

    function subDelegateBatched(address[] calldata targets, Rules[] calldata rules) external {
        address proxy = proxyAddress(msg.sender);
        if (proxy.code.length == 0) {
            create(msg.sender);
        }

        require(targets.length == rules.length);
        for (uint256 i = 0; i < targets.length; i++) {
            subDelegations[msg.sender][targets[i]] = rules[i];
            emit SubDelegation(msg.sender, targets[i], rules[i]);
        }
    }

    function validate(address sender, address[] memory authority, uint8 permissions, uint256 proposalId, uint8 support)
        public
        view
    {
        // authority is the chain of delegations
        // how to prove that caller has the permissions to do gov actions
        address from = authority[0];

        if (from == sender) {
            // owner has all permissions
            return;
        }

        // heh this could be optimized if we had EIP-2330 extsload so we could just load relevant slots
        INounsDAOV2.ProposalCondensed memory proposal = governor.proposals(proposalId);

        for (uint256 i = 1; i < authority.length; i++) {
            address to = authority[i];
            Rules memory rules = subDelegations[from][to];

            if ((rules.permissions & permissions) != permissions) {
                revert NotDelegated(from, to, permissions);
            }
            // min authority.length with a redelegation is 3.. ok
            // just sanity checking
            if (rules.maxRedelegations + i + 1 < authority.length) {
                revert TooManyRedelegations(from, to);
            }
            if (block.timestamp < rules.notValidBefore) {
                revert NotValidYet(from, to, rules.notValidBefore);
            }
            if (rules.notValidAfter != 0 && block.timestamp > rules.notValidAfter) {
                revert NotValidAnymore(from, to, rules.notValidAfter);
            }
            if (rules.blocksBeforeVoteCloses != 0 && proposal.endBlock > block.number + rules.blocksBeforeVoteCloses) {
                revert TooEarly(from, to, rules.blocksBeforeVoteCloses);
            }

            // customRule is sweet, guess this is used for things like checking proposal spending etc
            // but seems like this is a pretty big entry barrier for delegating, have to deploy a rules contract
            // but there could be shared rules contracts? ie. Spending limit contract for nouns that checks a proposal transfers less than 100eth
            // LOL ^ looks like you wrote one, I didn't see that until now
            if (rules.customRule != address(0)) {
                bytes4 selector = IRule(rules.customRule).validate(address(governor), sender, proposalId, support);
                if (selector != IRule.validate.selector) {
                    revert InvalidCustomRule(from, to, rules.customRule);
                }
            }

            from = to;
        }

        if (from == sender) {
            return;
        }

        revert NotDelegated(from, sender, permissions);
    }

    function _refundGas(uint256 startGas) internal {
        unchecked {
            uint256 balance = address(this).balance;
            if (balance == 0) {
                return;
            }
            uint256 basefee = min(block.basefee, MAX_REFUND_BASE_FEE);
            uint256 gasPrice = min(tx.gasprice, basefee + MAX_REFUND_PRIORITY_FEE);
            uint256 gasUsed = min(startGas - gasleft() + REFUND_BASE_GAS, MAX_REFUND_GAS_USED);
            uint256 refundAmount = min(gasPrice * gasUsed, balance);
            (bool refundSent,) = msg.sender.call{value: refundAmount}("");
            emit RefundableVote(msg.sender, refundAmount, refundSent);
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // Refill Alligator's balance for gas refunds
    receive() external payable {}
}

interface IENSReverseRegistrar {
    function setName(string memory name) external returns (bytes32 node);
}
