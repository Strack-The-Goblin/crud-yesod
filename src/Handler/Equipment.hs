{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Handler.Equipment where

import Import
import Lending
import Handler.LendingCommon
import Database.Persist.Sql (rawSql, toSqlKey, fromSqlKey)
import qualified Data.Text as T

categoryForm :: Maybe Category -> Form (Text, Text)
categoryForm value = renderDivs $ (,)
    <$> areq (requiredText 100) (textSettings "Nome *" "name") (categoryName <$> value)
    <*> areq (requiredText 2000) (textSettings "Descricao *" "description") (categoryDescription <$> value)

getCategoriesR :: Handler Html
getCategoriesR = do
    _ <- requireAdministrator
    categories <- runDB $ selectList [] [Asc CategoryName, Asc CategoryId]
    (widget, enctype) <- generateFormPost $ categoryForm Nothing
    defaultLayout $ do
        setTitle "Categorias"
        [whamlet|
            <h1>Categorias
            $if null categories
                <p>Nenhuma categoria cadastrada.
            $forall Entity cid category <- categories
                <section .panel.panel-default>
                    <div .panel-body>
                        <h2>#{categoryName category}
                        <p>#{categoryDescription category}
                        <a href=@{CategoryEditR cid}>Editar
                        ^{actionForm (CategoryDeleteR cid) "Excluir"}
            <h2>Nova categoria
            <form method=post action=@{CategoriesR} enctype=#{enctype}>
                ^{widget}
                <button .btn.btn-primary type=submit>Cadastrar
        |]

postCategoriesR :: Handler Html
postCategoriesR = do
    Entity uid _ <- requireAdministrator
    submitForm "Nova categoria" CategoriesR (categoryForm Nothing) $ \(name, description) -> do
        _ <- saveCategory uid Nothing name description
        pure CategoriesR

getCategoryEditR :: CategoryId -> Handler Html
getCategoryEditR cid = do
    _ <- requireAdministrator
    category <- runDB $ get404 cid
    (widget, enctype) <- generateFormPost $ categoryForm $ Just category
    editPage "Editar categoria" (CategoryEditR cid) widget enctype

postCategoryEditR :: CategoryId -> Handler Html
postCategoryEditR cid = do
    Entity uid _ <- requireAdministrator
    category <- runDB $ get404 cid
    submitForm "Editar categoria" (CategoryEditR cid) (categoryForm $ Just category) $ \(name, description) -> do
        _ <- saveCategory uid (Just cid) name description
        pure CategoriesR

postCategoryDeleteR :: CategoryId -> Handler Html
postCategoryDeleteR cid = do
    Entity uid _ <- requireAdministrator
    _ <- runDB $ get404 cid
    postEmpty
    runLending $ removeCategory uid cid
    setMessage "Categoria excluida."
    redirect CategoriesR

data EquipmentData = EquipmentData Text Text Text EquipmentCondition CategoryId

equipmentForm :: Maybe Equipment -> Form EquipmentData
equipmentForm value = renderDivs $ EquipmentData
    <$> areq (requiredText 100) (textSettings "Nome *" "name") (equipmentName <$> value)
    <*> areq (requiredText 4000) (textSettings "Descricao *" "description") (equipmentDescription <$> value)
    <*> areq (requiredText 100) (textSettings "Identificacao *" "identification") (equipmentIdentification <$> value)
    <*> areq conditionField (textSettings "Condicao *" "condition") (equipmentCondition <$> value)
    <*> areq (selectField categories) (textSettings "Categoria *" "category") (equipmentCategoryId <$> value)
  where
    categories = do
        values <- runDB $ selectList [] [Asc CategoryName, Asc CategoryId]
        optionsPairs $ map (\(Entity cid category) -> (categoryName category, cid)) values

getEquipmentNewR :: Handler Html
getEquipmentNewR = do
    _ <- requireActiveUser
    (widget, enctype) <- generateFormPost $ equipmentForm Nothing
    editPage "Publicar equipamento" EquipmentNewR widget enctype

postEquipmentNewR :: Handler Html
postEquipmentNewR = do
    Entity uid _ <- requireActiveUser
    submitForm "Publicar equipamento" EquipmentNewR (equipmentForm Nothing) $
        \(EquipmentData name description ident condition cid) -> do
            eid <- saveEquipment uid Nothing name description ident condition cid
            pure $ EquipmentR eid

getEquipmentEditR :: EquipmentId -> Handler Html
getEquipmentEditR eid = do
    (_, equipment) <- requireEquipmentOwner eid
    (widget, enctype) <- generateFormPost $ equipmentForm $ Just equipment
    editPage "Editar equipamento" (EquipmentEditR eid) widget enctype

postEquipmentEditR :: EquipmentId -> Handler Html
postEquipmentEditR eid = do
    (Entity uid _, equipment) <- requireEquipmentOwner eid
    submitForm "Editar equipamento" (EquipmentEditR eid) (equipmentForm $ Just equipment) $
        \(EquipmentData name description ident condition cid) -> do
            _ <- saveEquipment uid (Just eid) name description ident condition cid
            pure $ EquipmentR eid

postEquipmentDeleteR :: EquipmentId -> Handler Html
postEquipmentDeleteR eid = do
    (Entity uid _, _) <- requireEquipmentOwner eid
    postEmpty
    runLending $ removeEquipment uid eid
    setMessage "Equipamento excluido."
    redirect MyEquipmentR

getCatalogR :: Handler Html
getCatalogR = equipmentList False

getMyEquipmentR :: Handler Html
getMyEquipmentR = equipmentList True

equipmentList :: Bool -> Handler Html
equipmentList mine = do
    Entity uid _ <- requireActiveUser
    (search, category, page) <- runInputGet $ (,,)
        <$> iopt textField "name" <*> iopt (intField :: Field Handler Int64) "category" <*> iopt intField "page"
    let pageNumber = fromMaybe 1 page
        categoryId = fmap toSqlKey category
    when (pageNumber < 1 || pageNumber > 100000) $ invalidArgs ["Pagina invalida."]
    categories <- runDB $ selectList [] [Asc CategoryName, Asc CategoryId]
    forM_ categoryId $ \cid -> void $ runDB $ get404 cid
    let nameQuery = fromMaybe "" search
        escaped = T.concatMap (\c -> if c `elem` ("%_\\" :: String) then T.pack ['\\', c] else T.singleton c) nameQuery
        base = "SELECT ?? FROM equipment WHERE "
        ownerClause = if mine then "owner_id = ?" else
            "active = true AND owner_id IN (SELECT id FROM \"user\" WHERE active = true)"
        categoryClause = maybe "" (const " AND category_id = ?") categoryId
        nameClause = " AND name ILIKE ?"
        params = (if mine then [toPersistValue uid] else [])
            ++ maybe [] (\cid -> [toPersistValue cid]) categoryId
            ++ [PersistText $ "%" <> escaped <> "%", PersistInt64 21, toPersistValue ((pageNumber - 1) * 20 :: Int)]
    rows <- runDB $ rawSql (base <> ownerClause <> categoryClause <> nameClause <> " ORDER BY name, id LIMIT ? OFFSET ?") params
    items <- forM (take 20 rows) $ \(Entity eid equipment) -> do
        free <- runDB $ availableNow eid equipment
        pure (eid, equipment, free)
    let more = length rows > 20
        heading = if mine then ("Meus equipamentos" :: Text) else "Catalogo"
        route = if mine then MyEquipmentR else CatalogR
        pageParams n = [("name", nameQuery), ("page", tshow n)]
            ++ maybe [] (\cid -> [("category", tshow $ fromSqlKey cid)]) categoryId
    defaultLayout $ do
        setTitle "Equipamentos"
        [whamlet|
            <h1>#{heading}
            <p><a .btn.btn-primary href=@{EquipmentNewR}>Publicar equipamento
            <form method=get action=@{route}>
                <label>Nome
                <input name=name value=#{nameQuery}>
                <label>Categoria
                <select name=category>
                    <option value="">Todas
                    $forall Entity cid categoryValue <- categories
                        <option value=#{fromSqlKey cid} :(Just cid == categoryId):selected>#{categoryName categoryValue}
                <button type=submit>Filtrar
            <p>Disponibilidade informativa: reservas por periodo sao revalidadas ao aprovar e retirar.
            $if null items
                <p>Nenhum equipamento encontrado.
            $forall (eid, equipment, free) <- items
                <section .panel.panel-default>
                    <div .panel-body>
                        <h2><a href=@{EquipmentR eid}>#{equipmentName equipment}
                        <p>#{equipmentDescription equipment}
                        <p>#{availabilityLabel free}
            $if pageNumber > 1
                <a href=@?{(route, pageParams (pageNumber - 1))}>Anterior
            <span> Pagina #{pageNumber}
            $if more
                <a href=@?{(route, pageParams (pageNumber + 1))}>Proxima
        |]

getEquipmentR :: EquipmentId -> Handler Html
getEquipmentR eid = do
    Entity uid user <- requireActiveUser
    equipment <- runDB $ get404 eid
    owner <- runDB $ getJust $ equipmentOwnerId equipment
    unless (equipmentActive equipment && userActive owner
            || uid == equipmentOwnerId equipment || userRole user == Administrator) $
        permissionDenied "Equipamento inativo."
    category <- runDB $ getJust $ equipmentCategoryId equipment
    free <- runDB $ availableNow eid equipment
    reservations <- runDB $ selectList
        [LoanRequestEquipmentId ==. eid, LoanRequestStatus ==. Approved]
        [Asc LoanRequestStartsAt, Asc LoanRequestId]
    let isOwner = uid == equipmentOwnerId equipment
    defaultLayout $ do
        setTitle $ toHtml $ equipmentName equipment
        [whamlet|
            <h1>#{equipmentName equipment}
            <p>#{equipmentDescription equipment}
            <p>Categoria: #{categoryName category}
            <p>Condicao: #{conditionLabel $ equipmentCondition equipment}
            <p>Proprietario: #{userName owner}
            <p>#{availabilityLabel free}
            <h2>Periodos reservados (UTC-03:00)
            $if null reservations
                <p>Nenhuma reserva aprovada.
            $forall Entity _ reservation <- reservations
                <p>#{displayTime $ loanRequestStartsAt reservation} ate #{displayTime $ loanRequestEndsAt reservation}
            $if isOwner
                <p><a href=@{EquipmentEditR eid}>Editar equipamento
                <p><a href=@{EquipmentMaintenanceR eid}>Manutencoes
                ^{actionForm (EquipmentDeleteR eid) "Excluir equipamento sem historico"}
            $else
                $if equipmentActive equipment
                    <p><a .btn.btn-primary href=@{RequestNewR eid}>Solicitar equipamento
        |]

availabilityLabel :: Bool -> Text
availabilityLabel True = "Disponivel para consulta de periodo"
availabilityLabel False = "Indisponivel"
