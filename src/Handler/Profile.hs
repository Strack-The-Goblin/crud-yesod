{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
module Handler.Profile where

import Import
import Form.User
import ViaCEP
import Lending
import Handler.LendingCommon (runLending, actionForm, postEmpty)

getProfileR :: Handler Html
getProfileR = do
    Entity _ user <- requireActiveUser
    (formWidget, formEnctype) <- generateFormPost $ profileForm user
    profilePage user formWidget formEnctype

postProfileR :: Handler Html
postProfileR = do
    Entity uid user <- requireActiveUser
    ((result, formWidget), formEnctype) <- runFormPost $ profileForm user
    case result of
        FormSuccess profile -> do
            runLending $ do
                lockUsers [uid]
                fresh <- activeUser uid
                committed <- addressCommitted uid
                let oldAddress = [userPostalCode fresh, userStreet fresh, userNeighborhood fresh,
                        userCity fresh, userState fresh, userAddressNumber fresh, userAddressComplement fresh]
                    newAddress = [profilePostalCode profile, profileStreet profile, profileNeighborhood profile,
                        profileCity profile, profileState profile, profileAddressNumber profile, profileAddressComplement profile]
                ensure (not committed || oldAddress == newAddress)
                    "Endereco bloqueado enquanto houver reserva aprovada ou emprestimo aberto."
                update uid
                    [ UserName =. profileName profile
                    , UserPostalCode =. profilePostalCode profile
                    , UserStreet =. profileStreet profile
                    , UserNeighborhood =. profileNeighborhood profile
                    , UserCity =. profileCity profile
                    , UserState =. profileState profile
                    , UserAddressNumber =. profileAddressNumber profile
                    , UserAddressComplement =. profileAddressComplement profile
                    ]
            setMessage "Perfil atualizado."
            redirect ProfileR
        _ -> profilePage user formWidget formEnctype

profilePage :: User -> Widget -> Enctype -> Handler Html
profilePage user formWidget formEnctype = do
    (cepWidget, cepEnctype) <- generateFormPost postalCodeForm
    defaultLayout $ do
        setTitle "Meu perfil"
        $(widgetFile "profile")

postalCodeForm :: Form Text
postalCodeForm = renderDivs $ areq textField
    (FieldSettings "CEP para consultar" Nothing Nothing (Just "cep") []) Nothing

postProfileCEPR :: Handler Html
postProfileCEPR = do
    Entity _ user <- requireActiveUser
    ((result, cepWidget), cepEnctype) <- runFormPost postalCodeForm
    case result of
        FormSuccess cep -> do
            manager <- appHttpManager <$> getYesod
            address <- liftIO $ lookupPostalCode manager cep
            case address of
                Left message -> do
                    setMessage $ toHtml message
                    (formWidget, formEnctype) <- generateFormPost $ profileForm user
                    defaultLayout $(widgetFile "profile")
                Right found -> do
                    let filled = user
                            { userPostalCode = Just $ addressPostalCode found
                            , userStreet = nonEmpty $ addressStreet found
                            , userNeighborhood = nonEmpty $ addressNeighborhood found
                            , userCity = nonEmpty $ addressCity found
                            , userState = nonEmpty $ addressState found
                            }
                    setMessage "Endereco consultado na ViaCEP. Confira, complete os campos e confirme para salvar."
                    (widget, enctype) <- generateFormPost $ profileForm filled
                    profilePage filled widget enctype
        _ -> do
            setMessage "Informe o CEP e envie o formulario com um token valido."
            (formWidget, formEnctype) <- generateFormPost $ profileForm user
            defaultLayout $(widgetFile "profile")
  where
    nonEmpty value = if null value then Nothing else Just value

postProfileDeleteR :: Handler Html
postProfileDeleteR = do
    Entity uid _ <- requireActiveUser
    postEmpty
    runLending $ removeAccount uid
    clearCreds False
    setMessage "Conta sem vinculos excluida."
    redirect HomeR

postProfileDeactivateR :: Handler Html
postProfileDeactivateR = do
    Entity uid _ <- requireActiveUser
    postEmpty
    runLending $ deactivateAccount uid uid
    clearCreds False
    setMessage "Conta desativada; historico preservado."
    redirect HomeR
