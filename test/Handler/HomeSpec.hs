{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Handler.HomeSpec (spec) where

import TestImport

spec :: Spec
spec = withApp $ describe "Homepage" $ do
    it "shows the lending introduction and registration without scaffold forms" $ do
        get HomeR
        statusIs 200
        htmlAnyContain "h1" "O equipamento que voce precisa"
        htmlAnyContain ".home-actions a" "Criar minha conta"
        htmlAnyContain "footer" "Emprestimo de equipamentos entre alunos"
        htmlCount "form" 0
        htmlCount ".masthead" 0

    it "shows lending shortcuts for an authenticated student" $ do
        user <- createUser "student"
        authenticateAs user
        get HomeR
        statusIs 200
        htmlAnyContain ".home-actions a" "Explorar catalogo"
        htmlAnyContain ".home-actions a" "Minhas solicitacoes"
        htmlAnyContain ".home-actions a" "Publicar equipamento"
        htmlCount "form" 0
