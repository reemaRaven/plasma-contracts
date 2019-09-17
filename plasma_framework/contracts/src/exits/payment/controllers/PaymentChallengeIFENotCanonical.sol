pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;

import "../PaymentExitDataModel.sol";
import "../PaymentInFlightExitModelUtils.sol";
import "../routers/PaymentInFlightExitRouterArgs.sol";
import "../../interfaces/IOutputGuardHandler.sol";
import "../../interfaces/ISpendingCondition.sol";
import "../../models/OutputGuardModel.sol";
import "../../registries/OutputGuardHandlerRegistry.sol";
import "../../registries/SpendingConditionRegistry.sol";
import "../../utils/ExitId.sol";
import "../../utils/OutputId.sol";
import "../../utils/TxFinalization.sol";
import "../../../utils/UtxoPosLib.sol";
import "../../../utils/Merkle.sol";
import "../../../utils/IsDeposit.sol";
import "../../../framework/PlasmaFramework.sol";
import "../../../transactions/PaymentTransactionModel.sol";
import "../../../transactions/WireTransaction.sol";

library PaymentChallengeIFENotCanonical {
    using UtxoPosLib for UtxoPosLib.UtxoPos;
    using IsDeposit for IsDeposit.Predicate;
    using PaymentInFlightExitModelUtils for PaymentExitDataModel.InFlightExit;
    using TxFinalization for TxFinalization.Verifier;

    struct Controller {
        PlasmaFramework framework;
        IsDeposit.Predicate isDeposit;
        SpendingConditionRegistry spendingConditionRegistry;
        OutputGuardHandlerRegistry outputGuardHandlerRegistry;
        uint256 supportedTxType;
    }

    event InFlightExitChallenged(
        address indexed challenger,
        bytes32 txHash,
        uint256 challengeTxPosition
    );

    event InFlightExitChallengeResponded(
        address challenger,
        bytes32 txHash,
        uint256 challengeTxPosition
    );

    function buildController(
        PlasmaFramework framework,
        SpendingConditionRegistry spendingConditionRegistry,
        OutputGuardHandlerRegistry outputGuardHandlerRegistry,
        uint256 supportedTxType
    )
        public
        view
        returns (Controller memory)
    {
        return Controller({
            framework: framework,
            isDeposit: IsDeposit.Predicate(framework.CHILD_BLOCK_INTERVAL()),
            spendingConditionRegistry: spendingConditionRegistry,
            outputGuardHandlerRegistry: outputGuardHandlerRegistry,
            supportedTxType: supportedTxType
        });
    }

    function challenge(
        Controller memory self,
        PaymentExitDataModel.InFlightExitMap storage inFlightExitMap,
        PaymentInFlightExitRouterArgs.ChallengeCanonicityArgs memory args
    )
        public
    {
        uint192 exitId = ExitId.getInFlightExitId(args.inFlightTx);
        PaymentExitDataModel.InFlightExit storage ife = inFlightExitMap.exits[exitId];
        require(ife.exitStartTimestamp != 0, "In-fligh exit doesn't exists");

        require(ife.isInFirstPhase(self.framework.minExitPeriod()),
                "Canonicity challege phase for this exit has ended");

        require(
            keccak256(args.inFlightTx) != keccak256(args.competingTx),
            "The competitor transaction is the same as transaction in-flight"
        );


        UtxoPosLib.UtxoPos memory inputUtxoPos = UtxoPosLib.UtxoPos(args.inputUtxoPos);

        bytes32 outputId;
        if (self.isDeposit.test(inputUtxoPos.blockNum())) {
            outputId = OutputId.computeDepositOutputId(args.inputTx, inputUtxoPos.outputIndex(), inputUtxoPos.value);
        } else {
            outputId = OutputId.computeNormalOutputId(args.inputTx, inputUtxoPos.outputIndex());
        }
        require(outputId == ife.inputs[args.inFlightTxInputIndex].outputId,
                "Provided inputs data does not point to the same outputId from the in-flight exit");

        ISpendingCondition condition = self.spendingConditionRegistry.spendingConditions(
            args.outputType, self.supportedTxType
        );
        require(address(condition) != address(0), "Spending condition contract not found");
        bool isSpentByCompetingTx = condition.verify(
            args.inputTx,
            inputUtxoPos.outputIndex(),
            inputUtxoPos.txPos().value,
            args.competingTx,
            args.competingTxInputIndex,
            args.competingTxWitness,
            args.competingTxSpendingConditionOptionalArgs
        );
        require(isSpentByCompetingTx, "Competing input spending condition does not met");

        (IOutputGuardHandler outputGuardHandler, OutputGuardModel.Data memory outputGuardData) = verifyOutputTypeAndPreimage(self, args);

        // Determine the position of the competing transaction
        uint256 competitorPosition = verifyCompetingTxFinalized(self, args, outputGuardHandler, outputGuardData);

        require(
            ife.oldestCompetitorPosition == 0 || ife.oldestCompetitorPosition > competitorPosition,
            "Competing transaction is not older than already known competitor"
        );

        ife.oldestCompetitorPosition = competitorPosition;
        ife.bondOwner = msg.sender;

        // Set a flag so that only the inputs are exitable, unless a response is received.
        ife.isCanonical = false;

        emit InFlightExitChallenged(msg.sender, keccak256(args.inFlightTx), competitorPosition);
    }

    function respond(
        Controller memory self,
        PaymentExitDataModel.InFlightExitMap storage inFlightExitMap,
        bytes memory inFlightTx,
        uint256 inFlightTxPos,
        bytes memory inFlightTxInclusionProof
    )
        public
    {
        uint192 exitId = ExitId.getInFlightExitId(inFlightTx);
        PaymentExitDataModel.InFlightExit storage ife = inFlightExitMap.exits[exitId];
        require(ife.exitStartTimestamp != 0, "In-flight exit doesn't exists");

        require(
            ife.oldestCompetitorPosition > inFlightTxPos,
            "In-flight transaction has to be younger than competitors to respond to non-canonical challenge.");

        UtxoPosLib.UtxoPos memory utxoPos = UtxoPosLib.UtxoPos(inFlightTxPos);
        (bytes32 root, ) = self.framework.blocks(utxoPos.blockNum());
        ife.oldestCompetitorPosition = verifyAndDeterminePositionOfTransactionIncludedInBlock(
            inFlightTx, utxoPos, root, inFlightTxInclusionProof
        );

        ife.isCanonical = true;
        ife.bondOwner = msg.sender;

        emit InFlightExitChallengeResponded(msg.sender, keccak256(inFlightTx), inFlightTxPos);
    }

    function verifyAndDeterminePositionOfTransactionIncludedInBlock(
        bytes memory txbytes,
        UtxoPosLib.UtxoPos memory utxoPos,
        bytes32 root,
        bytes memory inclusionProof
    )
        private
        pure
        returns(uint256)
    {
        bytes32 leaf = keccak256(txbytes);
        require(
            Merkle.checkMembership(leaf, utxoPos.txIndex(), root, inclusionProof),
            "Transaction is not included in block of plasma chain"
        );

        return utxoPos.value;
    }

    function verifyOutputTypeAndPreimage(
        Controller memory self,
        PaymentInFlightExitRouterArgs.ChallengeCanonicityArgs memory args
    )
        private
        view
        returns (IOutputGuardHandler, OutputGuardModel.Data memory)
    {
        IOutputGuardHandler outputGuardHandler = self.outputGuardHandlerRegistry.outputGuardHandlers(args.outputType);

        require(address(outputGuardHandler) != address(0), "Failed to get the outputGuardHandler of the output type");

        WireTransaction.Output memory output = WireTransaction.getOutput(args.inputTx, args.inFlightTxInputIndex);
        OutputGuardModel.Data memory outputGuardData = OutputGuardModel.Data({
            guard: output.outputGuard,
            outputType: args.outputType,
            preimage: args.outputGuardPreimage
        });
        require(outputGuardHandler.isValid(outputGuardData),
                "Output guard information is invalid");

        return (outputGuardHandler, outputGuardData);
    }

    function verifyCompetingTxFinalized(
        Controller memory self,
        PaymentInFlightExitRouterArgs.ChallengeCanonicityArgs memory args,
        IOutputGuardHandler outputGuardHandler,
        OutputGuardModel.Data memory outputGuardData
    )
        private
        view
        returns (uint256)
    {
        // default to infinite low priority position
        uint256 competitorPosition = ~uint256(0);

        UtxoPosLib.UtxoPos memory competingTxUtxoPos = UtxoPosLib.UtxoPos(args.competingTxPos);
        uint256 competingTxType = WireTransaction.getTransactionType(args.competingTx);
        uint8 protocol = self.framework.protocols(competingTxType);

        if (args.competingTxPos == 0) {
            require(protocol == Protocol.MORE_VP(), "Competing tx without position must be a more vp tx");
        } else {
            TxFinalization.Verifier memory verifier = TxFinalization.Verifier({
                framework: self.framework,
                protocol: protocol,
                txBytes: args.competingTx,
                txPos: competingTxUtxoPos.txPos(),
                inclusionProof: args.competingTxInclusionProof,
                confirmSig: args.competingTxConfirmSig,
                confirmSigAddress: outputGuardHandler.getConfirmSigAddress(outputGuardData)
            });
            require(verifier.isStandardFinalized(), "Failed to verify the position of competing tx");

            competitorPosition = competingTxUtxoPos.value;
        }
        return competitorPosition;
    }
}
