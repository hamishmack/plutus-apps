{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE TypeOperators     #-}
{-# LANGUAGE ViewPatterns      #-}

module Cardano.Wallet.Client where

import qualified Cardano.Api
import           Cardano.Api.NetworkId.Extra                  (NetworkIdWrapper (..))
import qualified Cardano.Api.Shelley                          as Cardano.Api
import           Cardano.Node.Types                           (MockServerConfig (..))
import qualified Cardano.Wallet.Api                           as C
import qualified Cardano.Wallet.Api.Client                    as C
import           Cardano.Wallet.Api.Types                     (ApiVerificationKeyShelley (..), ApiWallet (..))
import qualified Cardano.Wallet.Api.Types                     as C
import qualified Cardano.Wallet.Primitive.AddressDerivation   as C
import qualified Cardano.Wallet.Primitive.Types               as C
import qualified Cardano.Wallet.Primitive.Types.Hash          as C
import qualified Cardano.Wallet.Primitive.Types.TokenMap      as C
import qualified Cardano.Wallet.Primitive.Types.TokenPolicy   as C
import qualified Cardano.Wallet.Primitive.Types.TokenQuantity as C
import qualified Cardano.Wallet.Primitive.Types.Tx            as C
import           Control.Monad.Freer                          (Eff, LastMember, Member, sendM, type (~>))
import           Control.Monad.Freer.Error                    (Error, throwError)
import           Control.Monad.Freer.Reader                   (Reader, ask)
import           Control.Monad.IO.Class                       (MonadIO (..))
import           Data.Aeson                                   (toJSON)
import           Data.Aeson.Extras                            (tryDecode)
import qualified Data.Aeson.Types                             as Aeson
import           Data.Bifunctor                               (bimap)
import           Data.Coerce                                  (coerce)
import           Data.Foldable                                (toList)
import           Data.Functor                                 (void)
import qualified Data.HashMap.Strict                          as Aeson
import           Data.Proxy                                   (Proxy (Proxy))
import           Data.Quantity                                (Quantity (..))
import           Data.Text                                    (pack)
import           Data.Text.Class                              (fromText)
import           Data.Text.Prettyprint.Doc                    (Pretty (..))
import           Ledger                                       (CardanoTx)
import qualified Ledger.Ada                                   as Ada
import           Ledger.Tx.CardanoAPI                         (SomeCardanoApiTx (..), ToCardanoError, toCardanoTxBody)
import           Ledger.Value                                 (CurrencySymbol (..), TokenName (..), Value (..))
import           Plutus.Contract.Wallet                       (export)
import           Plutus.V1.Ledger.Crypto                      (PubKeyHash (..))
import qualified PlutusTx.AssocMap                            as Map
import           PlutusTx.Builtins.Internal                   (BuiltinByteString (..))
import           Servant                                      ((:<|>) (..))
import           Servant.Client                               (ClientEnv, ClientError, ClientM, client, runClientM)
import           Wallet.Effects                               (WalletEffect (..))
import           Wallet.Emulator.Error                        (WalletAPIError (..))
import           Wallet.Emulator.Wallet                       (Wallet (..), WalletId (..))

getWalletKey :: C.ApiT C.WalletId -> C.ApiT C.Role -> C.ApiT C.DerivationIndex -> Maybe Bool -> ClientM ApiVerificationKeyShelley
getWalletKey :<|> _ :<|> _ :<|> _ = client (Proxy @C.WalletKeys)

handleWalletClient
    :: forall m effs.
    ( LastMember m effs
    , MonadIO m
    , Member (Error ClientError) effs
    , Member (Error WalletAPIError) effs
    , Member (Reader ClientEnv) effs
    , Member (Reader Cardano.Api.ProtocolParameters) effs
    )
    => MockServerConfig
    -> Wallet
    -> WalletEffect
    ~> Eff effs
handleWalletClient config (Wallet (WalletId walletId)) event = do
    let NetworkIdWrapper networkId = mscNetworkId config
    let mpassphrase = mscPassphrase config
    clientEnv <- ask @ClientEnv
    protocolParams <- ask @Cardano.Api.ProtocolParameters
    let
        runClient :: ClientM a -> Eff effs a
        runClient a = runClient' a >>= either throwError pure
        runClient' :: ClientM a -> Eff effs (Either ClientError a)
        runClient' a = sendM $ liftIO $ runClientM a clientEnv
    case event of
        SubmitTxn tx -> do
            sealedTx <- either (throwError . ToCardanoError) pure $ toSealedTx protocolParams networkId tx
            void . runClient $ C.postExternalTransaction C.transactionClient (C.ApiBytesT (C.SerialisedTx $ C.serialisedTx sealedTx))

        OwnPubKeyHash ->
            fmap (PubKeyHash . BuiltinByteString . fst . getApiVerificationKey) . runClient $
                getWalletKey (C.ApiT walletId) (C.ApiT C.UtxoExternal) (C.ApiT (C.DerivationIndex 0)) (Just True)

        BalanceTx utx ->
            case export protocolParams networkId utx of
                Left err -> throwOtherError $ pretty err
                Right ex -> do
                    res <- runClient' $ C.balanceTransaction C.transactionClient (C.ApiT walletId) (toJSON ex)
                    case res of
                        -- TODO: use the right error case based on http error code
                        Left err -> pure $ Left $ OtherError $ pack $ show err
                        Right (Aeson.Object (Aeson.toList -> [("transaction", Aeson.String hexCborTx)])) -> case tryDecode hexCborTx of
                            Left _ -> throwError $ OtherError "Received unexpected JSON data (invalid hex-encoded bytes) from transactions-balance endpoint"
                            Right cborTx ->
                                either throwOtherError (pure . Right . Left . (`SomeTx` Cardano.Api.AlonzoEraInCardanoMode)) $
                                    Cardano.Api.deserialiseFromCBOR (Cardano.Api.proxyToAsType Proxy) cborTx
                        Right _ -> throwError $ OtherError "Received unexpected JSON data from transactions-balance endpoint"

        WalletAddSignature tx -> do
            sealedTx <- either (throwError . ToCardanoError) pure $ toSealedTx protocolParams networkId tx
            passphrase <- maybe (throwError $ OtherError "Wallet passphrase required") pure mpassphrase
            lenientPP <- either throwOtherError pure $ fromText passphrase
            let postData = C.ApiSignTransactionPostData (C.ApiT sealedTx) (C.ApiT lenientPP) Nothing
            fmap fromApiSignedTransaction . runClient $ C.signTransaction C.transactionClient (C.ApiT walletId) postData

        TotalFunds -> do
            C.ApiWallet{balance, assets} <- runClient $ C.getWallet C.walletClient (C.ApiT walletId)
            let C.ApiWalletBalance (Quantity avAda) _ _ = balance
                C.ApiWalletAssetsBalance (C.ApiT avAssets) _ = assets
            pure $ Ada.lovelaceValueOf (fromIntegral avAda) <> tokenMapToValue avAssets

tokenMapToValue :: C.TokenMap -> Value
tokenMapToValue = Value . Map.fromList . fmap (bimap coerce (Map.fromList . fmap (bimap coerce (fromIntegral . C.unTokenQuantity)) . toList)) . C.toNestedList

fromApiSignedTransaction :: C.ApiSignedTransaction -> CardanoTx
fromApiSignedTransaction (C.ApiSignedTransaction (C.ApiT sealedTx) _ _) = Left $ case C.cardanoTx sealedTx of
    Cardano.Api.InAnyCardanoEra Cardano.Api.ByronEra tx   -> SomeTx tx Cardano.Api.ByronEraInCardanoMode
    Cardano.Api.InAnyCardanoEra Cardano.Api.ShelleyEra tx -> SomeTx tx Cardano.Api.ShelleyEraInCardanoMode
    Cardano.Api.InAnyCardanoEra Cardano.Api.AllegraEra tx -> SomeTx tx Cardano.Api.AllegraEraInCardanoMode
    Cardano.Api.InAnyCardanoEra Cardano.Api.MaryEra tx    -> SomeTx tx Cardano.Api.MaryEraInCardanoMode
    Cardano.Api.InAnyCardanoEra Cardano.Api.AlonzoEra tx  -> SomeTx tx Cardano.Api.AlonzoEraInCardanoMode

toSealedTx :: Cardano.Api.ProtocolParameters -> Cardano.Api.NetworkId -> CardanoTx -> Either ToCardanoError C.SealedTx
toSealedTx _ _ (Left (SomeTx tx Cardano.Api.ByronEraInCardanoMode)) = Right $ C.sealedTxFromCardano $ Cardano.Api.InAnyCardanoEra Cardano.Api.ByronEra tx
toSealedTx _ _ (Left (SomeTx tx Cardano.Api.ShelleyEraInCardanoMode)) = Right $ C.sealedTxFromCardano $ Cardano.Api.InAnyCardanoEra Cardano.Api.ShelleyEra tx
toSealedTx _ _ (Left (SomeTx tx Cardano.Api.AllegraEraInCardanoMode)) = Right $ C.sealedTxFromCardano $ Cardano.Api.InAnyCardanoEra Cardano.Api.AllegraEra tx
toSealedTx _ _ (Left (SomeTx tx Cardano.Api.MaryEraInCardanoMode)) = Right $ C.sealedTxFromCardano $ Cardano.Api.InAnyCardanoEra Cardano.Api.MaryEra tx
toSealedTx _ _ (Left (SomeTx tx Cardano.Api.AlonzoEraInCardanoMode)) = Right $ C.sealedTxFromCardano $ Cardano.Api.InAnyCardanoEra Cardano.Api.AlonzoEra tx
toSealedTx pp nid (Right tx) = C.sealedTxFromCardanoBody <$> toCardanoTxBody [] (Just pp) nid tx

throwOtherError :: (Member (Error WalletAPIError) effs, Show err) => err -> Eff effs a
throwOtherError = throwError . OtherError . pack . show
