{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Handler.Home where

import Import

getHomeR :: Handler Html
getHomeR = do
    muser <- maybeAuthPair
    defaultLayout $ do
        setTitle "Emprestimo de equipamentos"
        $(widgetFile "homepage")
