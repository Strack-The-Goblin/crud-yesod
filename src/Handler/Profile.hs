{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
module Handler.Profile where

import Import
import Form.User

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
            runDB $ update uid
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
profilePage user formWidget formEnctype =
    defaultLayout $ do
        setTitle "Meu perfil"
        $(widgetFile "profile")
