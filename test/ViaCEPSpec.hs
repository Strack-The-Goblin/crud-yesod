{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module ViaCEPSpec (spec) where

import TestImport
import ViaCEP
import Data.Either (isLeft)
import Control.Concurrent (threadDelay)
import Network.HTTP.Conduit (HttpException (..), HttpExceptionContent (ResponseTimeout), parseRequest)
import qualified Control.Exception as E
import qualified System.Timeout as Timeout

spec :: Spec
spec = describe "ViaCEP" $ do
    it "normalizes only spaces and hyphens and does not call HTTP for invalid input" $ do
        normalizePostalCode " 01310-100 " `shouldBe` Right "01310100"
        forM_ ["123", "01310.100", "01310/100", "abcdefgh"] $ \input -> do
            result <- lookupPostalCodeWith (\_ -> error "HTTP must not be called") input
            result `shouldSatisfy` isLeft

    it "uses the normalized CEP and decodes address fields including general CEPs" $ do
        result <- lookupPostalCodeWith (\cep -> do
            cep `shouldBe` "01310100"
            pure (200, "{\"logradouro\":\"Avenida Paulista\",\"bairro\":\"Bela Vista\",\"localidade\":\"Sao Paulo\",\"uf\":\"SP\"}"))
            "01310-100"
        result `shouldBe` Right (Address "01310100" "Avenida Paulista" "Bela Vista" "Sao Paulo" "SP")
        decodeAddress "12345678" "{\"localidade\":\"Cidade\",\"uf\":\"SP\"}"
            `shouldBe` Right (Address "12345678" "" "" "Cidade" "SP")

    it "reports nonexistent CEPs, malformed JSON, HTTP failures and timeouts explicitly" $ do
        decodeAddress "00000000" "{\"erro\":true}" `shouldBe` Left "CEP nao encontrado."
        forM_ [(503, "{}"), (200, "invalid"), (200, "{}")] $ \response -> do
            result <- lookupPostalCodeWith (const $ pure response) "01310100"
            result `shouldSatisfy` isLeft
        httpRequest <- parseRequest "https://viacep.com.br/ws/01310100/json/"
        failed <- lookupPostalCodeWith
            (\_ -> E.throwIO $ HttpExceptionRequest httpRequest ResponseTimeout) "01310100"
        failed `shouldSatisfy` isLeft

    it "bounds the whole HTTP operation even when the transport never responds" $ do
        result <- Timeout.timeout 6000000 $ lookupPostalCodeWith
            (\_ -> threadDelay 10000000 >> pure (200, "{}")) "01310100"
        case result of
            Just response -> response `shouldSatisfy` isLeft
            Nothing -> expectationFailure "ViaCEP exceeded the five-second operation timeout"
