{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Handler.Register where

import Import
import Form.User
import Password (hashPassword)

getRegisterR :: Handler Html
getRegisterR = do
    (widget, enctype) <- generateFormPost registrationForm
    registrationPage widget enctype

postRegisterR :: Handler Html
postRegisterR = do
    ((result, widget), enctype) <- runFormPost registrationForm
    case result of
        FormSuccess (Registration name ident password confirmation)
            | password /= confirmation -> do
                setMessage "As senhas nao conferem."
                registrationPage widget enctype
            | otherwise -> do
                createdAt <- liftIO getCurrentTime
                hashed <- hashPassword password
                inserted <- runDB $ insertUnique $ (newUser ident createdAt)
                    { userName = name, userPassword = Just hashed }
                case inserted of
                    Nothing -> do
                        setMessage "Este login ja esta cadastrado."
                        registrationPage widget enctype
                    Just _ -> do
                        setMessage "Conta criada. Entre com seu login e senha."
                        redirect $ AuthR LoginR
        _ -> registrationPage widget enctype

registrationPage :: Widget -> Enctype -> Handler Html
registrationPage widget enctype = defaultLayout $ do
    setTitle "Criar conta"
    [whamlet|
        <h1>Criar conta
        <p>Novas contas recebem o perfil de aluno.
        <form method=post action=@{RegisterR} enctype=#{enctype}>
            ^{widget}
            <button .btn.btn-primary type=submit>Criar conta
    |]
