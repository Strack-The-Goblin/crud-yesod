{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Form.User where

import Import
import qualified Data.Text as T
import Data.Char (isAscii, isAlphaNum)
import ViaCEP (normalizePostalCode)

data Registration = Registration Text Text Text Text

data ProfileData = ProfileData
    { profileName :: Text
    , profilePostalCode :: Maybe Text
    , profileStreet :: Maybe Text
    , profileNeighborhood :: Maybe Text
    , profileCity :: Maybe Text
    , profileState :: Maybe Text
    , profileAddressNumber :: Maybe Text
    , profileAddressComplement :: Maybe Text
    }

fieldSettings :: Text -> Text -> FieldSettings App
fieldSettings label name = FieldSettings (SomeMessage label) Nothing Nothing (Just name) []

nonBlankField :: Int -> Field Handler Text
nonBlankField limit = check validate textField
  where
    validate value
        | T.null (T.strip value) = Left ("Informe um valor, nao apenas espacos." :: Text)
        | T.length value > limit = Left ("Valor muito longo." :: Text)
        | otherwise = Right $ T.strip value

registrationForm :: Form Registration
registrationForm = renderDivs $ Registration
    <$> areq (nonBlankField 100) (fieldSettings "Nome" "name") Nothing
    <*> areq loginField (fieldSettings "Login" "username") Nothing
    <*> areq securePasswordField (fieldSettings "Senha (12 a 128 caracteres)" "password") Nothing
    <*> areq passwordField (fieldSettings "Confirme a senha" "confirmation") Nothing
  where
    loginField = checkBool validLogin ("Use 3 a 100 letras, numeros ou . _ @ - no login." :: Text) (nonBlankField 100)
    validLogin value = T.length value >= 3
        && T.all (\c -> isAscii c && (isAlphaNum c || c `elem` ("._@-" :: String))) value
    securePasswordField = checkBool
        (\value -> T.length value >= 12 && T.length value <= 128 && not (T.null $ T.strip value))
        ("A senha deve ter entre 12 e 128 caracteres e nao pode conter apenas espacos." :: Text)
        passwordField

profileForm :: User -> Form ProfileData
profileForm user = renderDivs $ ProfileData
    <$> areq (nonBlankField 100) (fieldSettings "Nome" "name") (Just $ userName user)
    <*> aopt postalCodeField (fieldSettings "CEP (8 digitos)" "postalCode") (Just $ userPostalCode user)
    <*> aopt (nonBlankField 200) (fieldSettings "Logradouro" "street") (Just $ userStreet user)
    <*> aopt (nonBlankField 100) (fieldSettings "Bairro" "neighborhood") (Just $ userNeighborhood user)
    <*> aopt (nonBlankField 100) (fieldSettings "Cidade" "city") (Just $ userCity user)
    <*> aopt stateField (fieldSettings "UF (sigla em maiusculas)" "state") (Just $ userState user)
    <*> aopt (nonBlankField 30) (fieldSettings "Numero" "addressNumber") (Just $ userAddressNumber user)
    <*> aopt (nonBlankField 200) (fieldSettings "Complemento" "addressComplement") (Just $ userAddressComplement user)
  where
    postalCodeField = checkMMap (pure . normalizePostalCode) id textField
    stateField = checkBool (`elem` states) ("Informe uma UF brasileira valida em maiusculas." :: Text) (nonBlankField 2)
    states = ["AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA", "MT", "MS",
              "MG", "PA", "PB", "PR", "PE", "PI", "RJ", "RN", "RS", "RO", "RR", "SC", "SP", "SE", "TO"]
