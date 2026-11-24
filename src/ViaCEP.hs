{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module ViaCEP
    ( Address (..), normalizePostalCode, decodeAddress, lookupPostalCode
    , lookupPostalCodeWith
    ) where

import ClassyPrelude
import Data.Aeson (Value (..), eitherDecode, withObject, (.:?), (.!=))
import Data.Aeson.Types (parseEither)
import qualified Data.Text as T
import Network.HTTP.Conduit
import Network.HTTP.Types.Status (statusCode)
import qualified Control.Exception as E
import qualified System.Timeout as Timeout

data Address = Address
    { addressPostalCode :: Text
    , addressStreet :: Text
    , addressNeighborhood :: Text
    , addressCity :: Text
    , addressState :: Text
    } deriving (Eq, Show)

normalizePostalCode :: Text -> Either Text Text
normalizePostalCode input =
    let cep = T.filter (\c -> c /= ' ' && c /= '-') input
    in if T.length cep == 8 && T.all (\c -> c >= '0' && c <= '9') cep
        then Right cep
        else Left "Informe um CEP com oito digitos (espacos e hifen sao permitidos)."

decodeAddress :: Text -> LByteString -> Either Text Address
decodeAddress cep body = do
    value <- either (const $ Left unavailable) Right $ eitherDecode body
    either (const $ Left unavailable) id $ parseEither parseAddress value
  where
    parseAddress = withObject "ViaCEP" $ \obj -> do
        missing <- obj .:? "erro"
        case missing of
            Just (Bool True) -> pure $ Left "CEP nao encontrado."
            Just (String "true") -> pure $ Left "CEP nao encontrado."
            _ -> do
                street <- obj .:? "logradouro" .!= ""
                neighborhood <- obj .:? "bairro" .!= ""
                city <- obj .:? "localidade" .!= ""
                state <- obj .:? "uf" .!= ""
                pure $ if T.null city || T.length state /= 2
                    then Left unavailable
                    else Right $ Address cep street neighborhood city state

unavailable :: Text
unavailable = "ViaCEP indisponivel. Tente novamente ou preencha o endereco manualmente."

lookupPostalCodeWith
    :: (Text -> IO (Int, LByteString)) -> Text -> IO (Either Text Address)
lookupPostalCodeWith fetch input = case normalizePostalCode input of
    Left err -> pure $ Left err
    Right cep -> do
        response <- Timeout.timeout 5000000 $
            (E.try (fetch cep) :: IO (Either HttpException (Int, LByteString)))
        pure $ case response of
            Nothing -> Left unavailable
            Just (Left _) -> Left unavailable
            Just (Right (200, body)) -> decodeAddress cep body
            Just (Right _) -> Left unavailable

lookupPostalCode :: Manager -> Text -> IO (Either Text Address)
lookupPostalCode manager = lookupPostalCodeWith $ \cep -> do
    request <- parseRequest $ "https://viacep.com.br/ws/" ++ unpack cep ++ "/json/"
    response <- httpLbs request
        { responseTimeout = responseTimeoutMicro 5000000
        , redirectCount = 0
        , checkResponse = \_ _ -> pure ()
        } manager
    pure (statusCode $ responseStatus response, responseBody response)
