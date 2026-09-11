#import "../funkcije.typ": todo
= Имплементација
<implementacija>

Ово поглавље приказује детаље имплементације целе платформе, од заједничких сандука до покретања. Прво су издвојени заједнички сандуци у потпоглављу @zajednicki-sanduci. Сервис за кориснике, сервис за каталог и сервис за библиотеку обрађени су у потпоглављима @korisnici-servis, @katalog-servis и @biblioteka-servis. Сервис за кориснички садржај, сервис за мултимедију и API _gateway_ обрађени су у потпоглављима @recenzije-servis, @multimedija-servis и @api-gateway-servis. Документација API-ја дата је у потпоглављу @dokumentacija. Затим следи клијентска апликација у потпоглављу @klijentska-aplikacija. На крају је дато покретање платформе у потпоглављу @pokretanje-platforme.

== Библиотечки сандуци `jwt-common` и `service-common`
<zajednicki-sanduci>

Заједничка основа издвојена је у два библиотечка сандука како се провера токена, облик грешака и приступ бази не би понављали у сваком сервису.

=== Сандук `jwt-common`
<jwt-common>

Набројив тип корисничких улога (`Role`) има три вредности: корисник, модератор и администратор. Скуп информација за JWT (`Claims`) носи просте типове: идентификатор, рокове и издаваоца, уз опционе улогу, корисничко име и имејл адресу - _access_ попуњава све, а _refresh_ само идентификатор. Конкретизоване структуре `RefreshTokenClaims` и `AuthClaims` настају провереним претварањем (`TryFrom`) из `Claims` и носе доменске типове: `Uuid` идентификатор, уз обавезан `Role` у `AuthClaims`.

Проверу токена спроводи ланац _middleware_-а (листинг @lst:jwt-middleware). Конфигурација `JwtConfig`, која носи учитани јавни RSA кључ, прослеђује се као _axum_ стање. `auth` издваја токен из заглавља, декодира га и убацује _claims_ у екстензије захтева. Омотачи `require_user`, `require_moderator` и `require_admin` око `require_roles` прослеђују дозвољене улоге заједничкој провери, која чита _claims_ и одбија недозвољене.

#figure(
```rust
pub async fn auth(
    State(config): State<JwtConfig>,
    mut req: Request,
    next: Next,
) -> Result<Response> {
    let token = extract_bearer_token(req.headers())
        .map_err(|err| JwtError::InvalidAuthorizationHeader(err.to_string()))?;
    let claims = decode_token(&token, &config.public_key)?;
    let auth_claims = AuthClaims::try_from(claims)?;
    req.extensions_mut().insert(auth_claims);
    Ok(next.run(req).await)
}

async fn require_roles(req: Request, next: Next, allowed_roles: &[Role]) -> Result<Response> {
    let claims = req.extensions().get::<AuthClaims>().ok_or(JwtError::MissingClaims)?;
    if !allowed_roles.contains(&claims.role) {
        Err(JwtError::Forbidden)
    } else {
        Ok(next.run(req).await)
    }
}
```,
  caption: [Провера токена и улога (`jwt-common/src/middleware.rs`)]
) <lst:jwt-middleware>

Варијанта `auth_optional` никада не одбија: _claims_ убацује само при успешном декодирању токена, за јавне руте са додацима за пријављене.

Грешке `JwtError` пресликавају се у статусе: неисправности заглавља, токена и _claims_ у 401, недовољна улога у 403, а неисправан кључ у 500.

=== Сандук `service-common`
<service-common>

Грешке обједињује `ApiError` (листинг @lst:api-error), сачињену од статусног кода и списка порука, који се враћају као JSON низ. Свака целина у сервисима понавља исти образац: дефинише сопствени тип грешке и алијас типа `Result<T>` везан за њега, уз претварање у `ApiError` преко `From`, па се грешке помоћу оператора `?` саме прослеђују _handler_-има који враћају `ApiResult`. Изузетак је _gateway_, чија грешка има сопствени одговор.

#figure(
```rust
#[derive(Debug)]
pub struct ApiError {
    pub code: StatusCode,
    pub errors: Vec<String>,
}

pub type Result<T> = std::result::Result<T, ApiError>;
```,
  caption: [Заједничка грешка и алијас типа `Result` (`service-common/src/error.rs`)]
) <lst:api-error>

Пагинација се постиже са `PagedResponse<T: ToSchema>` структуром: резултат претраге уз укупан број ставки, број страница, тренутна страница и граница.

Проверу постојања игре сервисима за библиотеку, мултимедију и кориснички садржај нуди `CatalogueClient`: позив ка сервису за каталог игара мапира се у успех, непостојање (`NotFound`) или недоступност (`Unavailable`). Клијент се гради са роком од 30 секунди.

Заједничка подешавања рутера примењују слојеве из поглавља @axum. CORS допушта локална порекла са креденцијалима (`cors_layer`), рок обраде је 10 секунди (`timeout_layer`), а обједињавање (`finalize_router`) доноси `/api`, `/docs` и границу тела захтева.

== Сервис за кориснике
<korisnici-servis>

Сервис за кориснике је власник података о налозима и једини издавалац аутентификационих токена (_access_ и _refresh_). Омогућава:
- регистрацију,
- пријаву,
- обнављање и повлачење токена,
- управљање профилом,
- измену лозинке,
- деактивацију налога и
- административне операције над улогама и блокирањем налога.

Јединственост корисничких имена, имејл адреса и токена обезбеђује се јединственим ограничењима на нивоу шеме, а корисник је обавештен одговарајућом поруком о грешци.

Лозинке се чувају хеширане алгоритмом Argon2 (листинг @lst:argon2, фајл `user-service/src/shared/password.rs`).

#figure(
```rust
pub fn hash_password(password: &str) -> Result<String, ValidationError> {
    let salt = SaltString::generate(&mut OsRng);
    let hash = Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map_err(|_| ValidationError::new(ERROR_MESSAGE))?;
    Ok(hash.to_string())
}
```,
  caption: [Хеширање лозинке алгоритмом Argon2 (`user-service/src/shared/password.rs`)]
) <lst:argon2>

Токени се потписују претходно генерисаним паром RSA кључева смештеним у фолдер `playlog-backend/keys`, према поступку из поглавља @bezbednosni-koncepti. Приватни кључ поседује искључиво овај сервис, док јавни кључ користе сви сервиси за проверу пристиглог токена преко функције из сандука `jwt-common`.

_Access_ токен носи идентификатор, улогу и основне податке корисника и важи подразумевано 300 секунди, док _refresh_ токен носи само идентификатор корисника и важи подразумевано 14 дана, према подели из поглавља @bezbednosni-koncepti. Скуп информација се обликује конструкторима `Claims::for_access_token` и `Claims::for_refresh_token`, а потписивање је обједињено у функцији `create_tokens` (листинг @lst:jwt-create).

#figure(
    ```rust
    pub fn create_tokens(access_token_validity: Duration, refresh_token_validity: Duration, jwt_private_key: &[u8], user_id: Uuid, role: Role, username: String, email: String) -> Result<(Tokens, DateTime<Utc>)> {
        let now = Utc::now();

        let expiration_date = now + access_token_validity;
        let claims = Claims::for_access_token(
            user_id.to_string(),
            expiration_date.timestamp() as usize,
            now.timestamp() as usize,
            role,
            username,
            email,
        );
        let access_token = create_token(claims, jwt_private_key)?;

        // refresh токен се генерише аналогно

        Ok((Tokens(access_token, refresh_token), expiration_date))
    }
    ```,
    caption: [Исечак функције за генерисање пара токена алгоритмом RS256 (скраћено из `user-service/src/auth/token.rs`)]
) <lst:jwt-create>

Провера пристиглог токена налази се у сандуку `jwt-common` (листинг @lst:jwt-decode).

#figure(
    ```rust
    pub fn decode_token(token: &str, public_key: &[u8]) -> Result<Claims> {
        let decoding_key = DecodingKey::from_rsa_pem(public_key)
            .map_err(|err| JwtError::InvalidDecodingKey(err.to_string()))?;
        let mut validation = Validation::new(Algorithm::RS256);
        validation.iss = Some(HashSet::from([String::from(ISSUER)]));
        let token_data = decode::<Claims>(token, &decoding_key, &validation)
            .map_err(|err| JwtError::InvalidToken(err.to_string()))?;
        Ok(token_data.claims)
    }
    ```,
    caption: [Функција за декодирање JWT токена (`jwt-common/src/token.rs`)]
) <lst:jwt-decode>

Животним циклусом токена управља структура `AuthService` (`user-service/src/auth/service.rs`). При пријави се налог проналази по корисничком имену или имејл адреси, при чему се блокирани налог одбија, а деактивирани третира као непостојећи. Након тога се лозинка проверава према сачуваном хешу. Успешном пријавом издаје се нови пар токена, а _refresh_ токен се уписује у базу са роком важења.

_Access_ токен се враћа у телу одговора, док се _refresh_ токен смешта у _HttpOnly_ колачић (`user-service/src/shared/cookie.rs`), па није доступан скриптама на клијенту. Обнављање _access_ токена спроводи ротацију описану у поглављу @bezbednosni-koncepti (листинг @lst:jwt-refresh): затечени токен се повлачи, а нови пар се издаје при чему се у базу уписује нови _refresh_ токен. Одјавом се _refresh_ токен повлачи у бази, а колачић се поништава.

#figure(
    ```rust
    pub async fn refresh_tokens(&self, config: &AppConfig, token: &str) -> Result<Tokens> {
        if !self.repository.is_token_valid(token).await? {
            return Err(AuthError::TokenError(String::from("Invalid token!")));
        }
        let claims = decode_token(token, &config.jwt_public_key)
            .and_then(RefreshTokenClaims::try_from)
            .map_err(|err| AuthError::TokenError(err.to_string()))?;
        self.revoke_token(token).await?;
        let user = self
            .repository
            .find_by_id(claims.user_id)
            .await?
            .ok_or(AuthError::UserNotFound)?;
        let tokens = self.generate_tokens(config, user).await?;
        Ok(tokens)
    }
    ```,
    caption: [Ротација _refresh_ токена (`user-service/src/auth/service.rs`)]   
) <lst:jwt-refresh>

Истекли токени се периодично бришу позадинским задатком (`user-service/src/task.rs`), који се покреће при покретању сервиса и извршава једном дневно.

При покретању сервиса иницијализује се предефинисани администратор са креденцијалима уписаним у `.env` датотеци (`user-service/src/main.rs`, `AuthService::ensure_admin`). Налог се креира само када нема администратора у систему (при првом покретању), уз исте провере јединствености као при регистрацији, а рад сервиса се спречава све док се не креира налог предефинисаног администратора.

`auth/` руте су јавне, при чему пријава и регистрација не траже токен, а одјава и обнављање имају колачић за _refresh_ токен. Преглед туђег профила је јаван, личне операције стоје иза `require_user`, а претрага, промене улога и блокирање иза `require_admin`.

== Сервис за каталог
<katalog-servis>

Сервис за каталог представља централни извор података о играма. Чува основне податке о играма (назив, опис, датум изласка, веб сајт) и пратеће ентитете: 
- програмере, 
- издаваче, 
- жанрове,
- платформе и
- ознаке, 
при чему свака врста има засебну табелу. Игре пролазе кроз животни циклус од нацрта до објаве, при чему је нацрт видљив искључиво администраторима. Брисање је могуће само док је игра нацрт.

Интегритет на нивоу шеме базе података обезбеђују јединствени страни кључеви са каскадним брисањем у везама игара са пратећим ентитетима. Примењени су индекси из поглавља @postgres (листинг @lst:db-indeksi): GIN триграмски индекси за текстуалну претрагу назива и индекси над страним кључевима за спајања са пратећим ентитетима.

#figure(
```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_games_name ON games USING gin (name gin_trgm_ops);
CREATE INDEX idx_developers_name ON developers USING gin (name gin_trgm_ops);
CREATE INDEX idx_game_developers_developer_id ON game_developers (developer_id);
CREATE INDEX idx_game_tags_tag_id ON game_tags (tag_id);
```,
  caption: [Исечак индекса сервиса за каталог (`catalogue-service/migrations/20260218212643_init.up.sql`)]
) <lst:db-indeksi>

_Trait_ `GameRepository` (листинг @lst:catalog-repo) прописује операције над играма, док пратећи ентитети деле _trait_-ове `GameEntityRepository` (операције `SELECT`, `INSERT`, `UPDATE`) и `DeletableGameEntityRepository` (операција `DELETE`). Ентитети програмера и издавача не могу да се бришу.

#figure(
```rust
#[async_trait]
pub trait GameRepository: Send + Sync {
    async fn filter(
        &self,
        include_drafts: bool,
        params: GameFilterQuery,
    ) -> Result<Vec<GameSimple>>;
    // ...
    async fn get_details(&self, id: i32, include_draft: bool) -> Result<Option<GameDetails>>;
    async fn create(&self, data: CreateGameRequest) -> Result<Game>;
    async fn update(&self, id: i32, data: UpdateGameRequest) -> Result<GameDetails>;
    async fn publish(&self, id: i32, version: i64) -> Result<Game>;
    async fn delete(&self, id: i32, version: i64) -> Result<()>;
}
```,
  caption: [Исечак `GameRepository` _trait_-а (скраћено из `catalogue-service/src/games/repository.rs`)]
) <lst:catalog-repo>

Структура `GameService` чува `Box<dyn GameRepository>` и репозиторијуме пратећих ентитета као `Box<dyn GameEntityRepository>`, али пословну логику спроводи само за игре: репозиторијуми ентитета служе искључиво за проверу постојања ентитета при додавању или измене игре (`catalogue-service/src/app.rs`). 

Пратећи ентитети игре деле заједнички модел (`GameEntity`) и имплементацију репозиторијума (`PostgresGameEntityRepository`). Не захтевају посебан сервисни слој, па њихови _handler_-и користе репозиторијуме директно.

Упит за претрагу са филтрирањем игара методе `GameRepository::filter` се склапа помоћу `QueryBuilder`: полази се од `DISTINCT` уз `LEFT JOIN` ка везама ознака, жанрова и платформи, затим се додају опциони `IN` филтери и `ILIKE` услов са пречишћеним обрасцем. Сортирање је задато набројивим типом, а странице обухватају до 10 записа. Детаљи игре се добијају методом `GameRepository::get_details`, једним упитом за игру и са пет упита за пратеће ентитете.

Методе `create` и `update` извршавају се трансакционо, како би ред игре и везе ка пратећим ентитетима заједно успели или заједно отказали: ред игре се упише или измени, а затим помоћне методе `set_*` обнављају везе брисањем по игри и поновним уписом по идентификатору. При измени се дирају само прослеђене `Option<Vec<i32>>` везе. Структура `GameService` пре уписа проверава идентификаторе: изостављени пролазе, празан скуп се одбија, а сваки наведени мора постојати.

Методе `publish`, `update` и `delete` користе верзију записа за оптимистично закључавање @fowler2002. Објављивање (листинг @lst:catalog-publish) у једном `WHERE` спаја проверу верзије и заштиту нацрта, уз увећање верзије. Ако ниједан ред није измењен, накнадни упит разликује узроке: непостојећа игра је `NotFound`, објављена је `AlreadyPublished`, а измењена у међувремену је `Conflict`. Конфликти се пресликавају у одговор 409. Исти образац важи за измену игре и `update_name` пратећих ентитета, где се назив табеле добија из `table_name` уз `AssertSqlSafe`.

#figure(
```rust
let game = query_as!(
    Game,
    r#"
        UPDATE games
        SET draft = false, version = version + 1
        WHERE id = $1 AND version = $2 AND draft = true
        RETURNING id, name, description, released, website, draft, version
    "#,
    id,
    version
)
.fetch_optional(&self.pool)
.await?;
match game {
    Some(game) => Ok(game),
    None => {
        // SELECT draft ...: нема реда = NotFound,
        // објављена = AlreadyPublished, нацрт = Conflict
    }
}
```,
  caption: [Објављивање игре уз проверу верзије (скраћено из `catalogue-service/src/games/repository.rs`)]
) <lst:catalog-publish>

Руте су подељене према _middleware_-има који их штите (листинг @lst:catalog-router): јавне `GET` руте стоје иза `auth_optional`, а уписи и преглед необјављених игара иза `auth` и `require_admin`. Из `AuthClaims` се преузима улога, па администратор у претрази и детаљима види и нацрте, а остали само објављене игре.

#figure(
```rust
pub fn router(state: Arc<AppState>) -> OpenApiRouter<Arc<AppState>> {
    let jwt_config = JwtConfig::new(state.config.jwt_public_key.clone());
    let public_routes = OpenApiRouter::new()
        .route("/filter", get(filter))
        .route("/{id}/details", get(get_details))
        // ... споредне GET руте
        .route_layer(from_fn_with_state(jwt_config.clone(), auth_optional));
    let admin_routes = OpenApiRouter::new()
        .route("/", post(create))
        .route("/unpublished", get(get_unpublished))
        .route("/{id}", put(update))
        .route("/{id}", delete(delete_game))
        .route("/{id}/publish", put(publish))
        .route_layer(from_fn(require_admin))
        .route_layer(from_fn_with_state(jwt_config, auth));
    OpenApiRouter::new().merge(public_routes).merge(admin_routes)
}
```,
  caption: [Раздвајање јавних и администраторских рута (скраћено из `catalogue-service/src/games/handler.rs`)]
) <lst:catalog-router>

== Сервис за библиотеку 
<biblioteka-servis>

Библиотека бележи везу између корисника и игре у табели `user_games`, уз један од пет статуса из поглавља @funkcionalni-biblioteka. Јединствене везе на нивоу шеме обезбеђује сложени примарни кључ (корисник, игра).

Упис најпре проверава постојање игре преко `CatalogueClient`: непостојање у каталогу постаје `InvalidGameId` (404), а сваки други исход `CatalogueServiceError` (502). Додавање и измена статуса изводе се једним уписом (листинг @lst:library-upsert): при конфликту на сложеном кључу освежавају се само статус и време измене, а ред се враћа.

#figure(
```rust
let game = query_as!(
    UserGame,
    r#"
    INSERT INTO user_games (user_id, game_id, status)
    VALUES ($1, $2, $3)
    ON CONFLICT (user_id, game_id) DO UPDATE
    SET status = EXCLUDED.status, last_updated = now()
    RETURNING user_id, game_id, status AS "status: GameLibraryStatus", added_at, last_updated
    "#,
    user_id,
    game_id,
    status as _
)
.fetch_one(&self.pool)
.await?;
Ok(game)
```,
  caption: [Упис или измена статуса једним упитом (`library-service/src/repository.rs`)]
) <lst:library-upsert>

Читање се изводи преко `COUNT`, па `SELECT` са опционим филтером статуса, од најскорије измењених, уз ограничену страницу и границу, у облику `PagedResponse`.

Брисање без погођеног реда враћа `NotFound`, а нарушавања јединствености и страног кључа мапирају се у 409.

Идентификатор корисника за упис преузима се искључиво из `Extension<AuthClaims>`, никада из путање или тела захтева, па корисник има право да мења само сопствене редове. Руте за операције над библиотеком су заштићене помоћу `require_user`, а читање је јавно са идентификатором из путање.

== Сервис за кориснички садржај
<recenzije-servis>

Садржај чине три колекције докумената са денормализованим корисничким именима:
- оцене (четири вредности из @funkcionalni-ocene) са опционим текстом рецензије, 
- коментари са циљем (игра или оцена) и
- пријаве са циљем (коментар или оцена), подносиоцем, разлогом и животним циклусом.

Једна активна оцена по кориснику и игри, као и једна пријава на чекању, обезбеђују се делимично јединственим индексима на нивоу шеме. Читања убрзавају сложени индекси према игри, оцени и циљу.
Упис оцене најпре проверава постојање игре у каталогу (404/502). Затечена оцена се преписује условно верзијом, а нова убацује са почетном верзијом (листинг @lst:review-upsert). Неуспела замена због неслагања верзије пресликава се у `Conflict`.

#figure(
```rust
match review.id {
    Some(id) => {
        let current_version = review.version;
        review.version += 1;
        let filter = doc! { "_id": id, "version": current_version };
        let result = self.reviews.replace_one(filter, review.clone()).await?;
        if result.matched_count == 0 {
            return Err(ReviewError::Conflict(id));
        }
        Ok(review)
    }
    None => {
        // ... insert_one са преузимањем додељеног идентификатора ...
    }
}
```,
  caption: [Упис оцене уз проверу верзије (скраћено из `review-service/src/review/repository.rs`)]
) <lst:review-upsert>

Измена и брисање учитавају документ и пореде аутора са идентитетом из токена. Брисање је логичко: поставља `deleted` уз увећање верзије, а обрисано се чита као непостојеће.

Подношење пријаве одбија дуплу пријаву на чекању поднету од стране истог корисника за исти садржај. Разрешење (листинг @lst:report-resolve) одбија разрешавање сопствене пријаве и допушта само прелазе са чекања: уважавање логички брише циљани документ (оцену или коментар) кроз његов репозиторијум, а ред пријаве се пребацује уз проверу верзије, па двострука модерација завршава конфликтом.

#figure(
```rust
let report = self.report_repository.find_by_id(id).await?
    .ok_or(ReportError::NotFound)?;
if report.reporter_id == resolver_id {
    return Err(ReportError::CantResolveOwnReport);
}
if report.status != ReportStatus::Pending {
    return Err(ReportError::IllegalStatus(report.status.as_db_value()));
}
if let ReportStatus::Resolved = status {
    // ... логичко брисање циља кроз репозиторијум рецензија или коментара ...
}
self.report_repository.update_report_status(id, status, version).await
```,
  caption: [Разрешавање пријаве (скраћено из `review-service/src/report/service.rs`)]
) <lst:report-resolve>

Збирови се израчунавају агрегацијама (`$group`, `$avg`, `$sort`): статистика по оценама, најбоље оцењене и највише оцењиване игре, уз број коментара по рецензији. Читања су јавна, док уписи рецензија, коментара и пријава стоје иза `require_user`, а листа чекања и разрешавање иза `require_moderator`.

== Сервис за мултимедију 
<multimedija-servis>

Сервис за мултимедију чува слике и видео записе игара: бајтове у објектном складишту, а метаподатке у бази докумената. Један медијски документ по игри обезбеђује се јединственим индексом на нивоу шеме. Документ носи верзионисане метаподатке (насловну слику, снимке екрана и трејлер као записе са кључем објекта, MIME типом и величином), док су бајтови фајлова у објектном складишту. Три именована поља отпремања (`cover`, `screenshot`, `trailer`) мапирају се у набројив тип `FieldName`.

Најпре се проверава постојање игре (404/502). Отпремање затим ограничава садржај: највише 22 датотеке (насловна слика, трејлер и максимално 20 снимака екрана). Слике су ограничене на 10 MB, а видео на 500 MB, уз проверу MIME типа по пољу. Отпремање се одвија под привременим кључевима са ознаком покушаја, а први упис настаје са почетном верзијом. Истовремене прве отпреме сударају се на јединственом индексу: пролази само једна.

При измени затеченог документа верзија се најпре проверава у меморији, пре постављања бајтова у објектно складиште. Затим следе постављање и спајање новог садржаја са затеченим документом уз увећање верзије. Ознака покушаја раздваја истовремене отпреме под различите кључеве, па кроз верзионисани упис пролази само једна. Неуспешан верзионисани упис (листинг @lst:media-upload) враћа `Conflict` и брише управо постављене кључеве, а замењени (стари) кључеви бришу се тек по успеху.

#figure(
```rust
self.validate_upload_limits(&files)?;
let existing = self.repository.find_by_game_id(game_id).await?
    .unwrap_or_else(|| GameMedia::new_for_game(game_id));
if existing.version != version {
    return Err(MediaError::Conflict(game_id));
}
let (new_cover, new_screenshots, new_trailer) =
    self.process_and_upload_files(game_id, files).await?;
// ... спајање новог са затеченим уз version + 1 ...
if let Err(error) = self.repository.upsert(media, version).await {
    self.storage.delete_keys(&uploaded_keys).await;
    return Err(error);
}
self.storage.delete_keys(&replaced_keys).await;
```,
  caption: [Отпремање са провером верзије и враћањем постављеног (скраћено из `multimedia-service/src/service.rs`)]
) <lst:media-upload>

Кључна одлика је да сервис при читању никада не прослеђује бајтове кроз себе, већ за сваки тражени фајл генерише URL са роком важења од једног сата, према приступу из поглавља @minio-sanduk (листинг @lst:presign):

#figure(
```rust
async fn presign(&self, object_key: &str) -> Result<String> {
    self.client
        .get_presigned_object_url(&self.bucket, object_key, Method::GET)
        .expiry_seconds(60 * 60)
        .send()
        .await
        .map(|response| response.url)
        .map_err(|e| MediaError::StorageError(e.to_string()))
}
```,
  caption: [Стварање унапред потписаног URL-а ка објектном складишту (`multimedia-service/src/storage.rs`)]
) <lst:presign>

Групне насловне слике разрешавају се једним `$in` упитом и враћају се као мапа идентификатор-URL, где недостајући запис добија вредност `null` (до 100 идентификатора, празан улаз даје празан излаз).

Брисање проверава верзију у меморији, затим верзионисано брише документ (непостојећи је `NotFound`, затечени `Conflict`), па брише кључеве из складишта.

Рок обраде (600 секунди) и граница тела захтева (512 MB) прилагођени су величини видео записа. Грешке валидације су 400. Непостојање, конфликт и каталог носе 404, 409 и 502, а откази складишта и базе прикривени су 500 уз евиденцију. Читања су јавна, а отпремање и брисање чува `require_admin`.

== API _gateway_ сервис
<api-gateway-servis>

API _gateway_ је по обрасцу из поглавља @mikroservisni-obrasci једина улазна тачка платформе и једини сервис без складишта. За остале сервисе иницијализује посебно стање `ServiceAppState`: адресу сервиса, дељени `ProxyClient` и `JwtConfig`. Дељени клијент носи рок обраде и границу тела захтева прилагођене отпремањима видеа која пролазе кроз _proxy_ ка сервису за мултимедију.

Рутер за сваки сервис понавља путање тог сервиса, а све показују на универзални `proxy_handler` (листинг @lst:gateway-proxy). Јавне руте немају заштиту, а заштићене стоје иза `auth` и одговарајуће провере улоге. Одбијени захтев никада не стиже до сервиса, али се заглавље `Authorization` прослеђује даље, па сервис поновно проверава потпис, по обрасцу _zero trust_ @adanigbo2024.

#figure(
    caption: [универзални _proxy handler_ за _endpoint_-ове свих сервиса (`api-gateway/src/proxy/handler.rs`)],
    ```rust
    #[debug_handler]
    pub async fn proxy_handler(
        State(state): State<Arc<ServiceAppState>>,
        OriginalUri(original_uri): OriginalUri,
        request: Request,
    ) -> Result<Response> {
        let (parts, body) = request.into_parts();
        let path = original_uri.path();
        let path = if let Some(query) = parts.uri.query() {
            format!("{}?{}", path, query)
        } else {
            path.to_string()
        };
        state
            .proxy_client
            .forward_request(&state.service_url, &path, parts.method, parts.headers, body)
            .await
    }
    ```
) <lst:gateway-proxy>

Прослеђивање (листинг @lst:gateway-forward) саставља адресу, одбацује заглавља везе и регенерисана заглавља (`Host`, `Content-Length`). Преостала заглавља чува, укључујући и `Authorization`. Тело се стримује без баферовања, па видео пролази без оптерећења меморије. Одговор се враћа са статусом, заглављима и бајтовима.

#figure(
    caption: [Прослеђивање захтева ка сервису (`api-gateway/src/proxy/client.rs`)],
    ```rust
    pub async fn forward_request(
        &self,
        service_url: &str,
        path: &str,
        method: Method,
        headers: HeaderMap,
        body: Body,
    ) -> Result<Response> {
        let base = service_url.trim_end_matches('/');
        let url = format!("{}{}", base, path);
        let mut request = self.client.request(method.clone(), &url);
        for (header_name, header_value) in headers
            .iter()
            .filter(|(header_name, _)| should_forward_header(header_name.as_str()))
        {
            request = request.header(header_name, header_value);
        }
        request = request.body(reqwest::Body::wrap_stream(body.into_data_stream()));
        let response = request.send().await.map_err(|e| {
            GatewayError::ServiceUnavailable(format!("Failed to reach service: {}", e))
        })?;
        // Конвертовање reqwest::Response у axum::Response
        Self::convert_response(response).await
    }
    ```
) <lst:gateway-forward>

Грешка `GatewayError` има сопствени облик `{"error"}`: недоступан сервис је 503, а нечитљив одговор 502. Алијас типа `Result` прати образац осталих целина.

При покретању _gateway_ преузима _OpenAPI_ спецификацију сваког сервиса и спаја их у јединствени приказ (листинг @lst:docs-merge), а неуспело преузимање само се евидентира.

#figure(
    caption: [Спајање спецификација сервиса (скраћено из `api-gateway/src/docs.rs`)],
    ```rust
    pub async fn load_service_docs(config: &Config, client: &Client) -> OpenApiDocument {
        let mut merged = ApiDoc::openapi();
        let service_urls: Vec<&str> = vec![
            // ... адресе свих сервиса ...
        ];
        for base_url in service_urls {
            match fetch_service_doc(client, base_url).await {
                Ok(spec) => merged.merge(spec),
                Err(err) => error!("Failed to load OpenAPI spec from {}: {err}", base_url),
            }
        }
        merged
    }
    ```
) <lst:docs-merge>

== Документација API-ја
<dokumentacija>

Принцип генерисања документације је описан у поглављу @utoipa. Сваки сервис пријављује своје _handler_-е у декларацију `ApiDoc` (листинг @lst:utoipa). Омотач `OpenApiRouter` прикупља спецификацију уз регистрацију рута, а додатак `SecurityAddon` пријављује _bearer_ шему за заштићене руте. Приказани _Swagger_ UI омогућава испробавање рути сервиса пре израде клијента.

#figure(
    ```rust
    #[utoipa::path(
        post,
        path = "/api/auth/register",
        request_body = RegisterRequest,
        summary = "Register new user",
        responses(
            (status = 201, description = "Successful register", body = RegisterResponse),
            (status = 400, description = "Request has missing values, or the values are invalid"),
            (status = 409, description = "Email or username is already taken"),
        ),
        tag = "auth",
    )]
    #[debug_handler]
    pub async fn register(
        State(state): State<Arc<AppState>>,
        Json(request): Json<RegisterRequest>,
    ) -> ApiResult<impl IntoResponse> {
        request.validate().map_err(ApiError::from)?;
        let result = state.auth_service.register(request).await?;
        Ok((StatusCode::CREATED, Json(result)).into_response())
    }
    ```,
    caption: [Декларативни _OpenAPI_ макро _handler_-a за регистрацију (исечак из `user-service/src/auth/handler.rs`)]
) <lst:utoipa>

== Клијентска апликација
<klijentska-aplikacija>

Клијентска апликација обрађена је кроз радни оквир _Angular_ у поглављу @klijent-angular и веб сервер _nginx_ у поглављу @klijent-nginx. У развоју _nginx_ се не користи, већ _Angular development_ сервер директно упућује захтеве ка API _gateway_-у.

=== _Angular_
<klijent-angular>

Клијент је изграђен од самосталних (енгл. _standalone_) компоненти, са засебном компонентом по страници. _Access_ токен се складишти у `localStorage` (кључ `playlogAccessToken`), а _refresh_ токен искључиво у `_HttpOnly_` колачићу уз `withCredentials`. Корисник се одређује декодирањем токена, а без токена је гост. Пријава на систем складишти токене, одјава га уклања уз повлачење _refresh_ токена на серверу. При покретању апликације и освежавању странице на претраживачу затечени истекли токен се освежава.

Пресретач `AuthInterceptor` на све руте осим четири `auth/` руте додаје `Bearer` заглавље. При истеку токена најпре освежава одвојеним HTTP клијентом (који заобилази `AuthInterceptor`, како не би дошло до рекурзије), уз обједињавање истовремених освежавања, па понавља захтев (листинг @lst:auth-interceptor). Неуспешно освежавање одјављује корисника, враћа га на почетну страницу и приказује обавештење. Истеклост се проверава пре слања захтева, па се одговор 401 никада не понавља.

#figure(
```ts
if (this.sessionService.isTokenExpired()) {
  return this.sessionService.refreshToken().pipe(
    switchMap((newToken) => {
      const cloned = req.clone({
        setHeaders: { Authorization: `Bearer ${newToken}` },
      });
      return next.handle(cloned);
    }),
    catchError((err) => throwError(() => err))
  );
}
```,
  caption: [Освежавање и понављање захтева (скраћено из `app/core/interceptors/auth.interceptor.ts`)]
) <lst:auth-interceptor>

Чувар `authGuard` проверава улогу корисника према тренутној рути и враћа на почетну странцу при било каквом неслагању (листинг @lst:auth-guard).

#figure(
```ts
export const authGuard: CanActivateFn = (route: ActivatedRouteSnapshot) => {
  const sessionService = inject(SessionService);
  const router = inject(Router);
  const user = sessionService.user();
  const roles = route.data['roles'] as Role[];
  if (!roles || roles.length === 0) {
    return true;
  }
  if (!roles.includes(user.role)) {
    router.navigate(["home"]);
    return false;
  }
  return true;
};
```,
  caption: [Заштита руте према улози (скраћено из `app/core/guards/auth.guard.ts`)]
) <lst:auth-guard>

=== _nginx_
<klijent-nginx>

Датотека `nginx.conf` примењује улоге описане у поглављу @nginx: статичке датотеке сервира са диска уз повратак на `index.html` за клијентске руте. Почетна страница се не кешира зато што је _Angular_ једностранична (енгл. _single page_) апликација, а хеширане датотеке су непроменљиве годину дана.

`/api/` прослеђује ка адреси из окружења уз заглавља прослеђивања, чиме релативни `/api` стиже до API _gateway_-а. Такође прослеђује захтеве упућене објектном складишту (које није изложено изван _Docker_ мреже у продукцији), па прегледач слике са `img src` адреса добавља директно из складишта.

`nginx.conf` садржи и ограничење величине тела захтева од 500 MB, према највећем дозвољеном отпремању, уз прикривање верзије сервера.

== Покретање платформе
<pokretanje-platforme>

_Docker_ слике сервиса се граде вишестепено (листинг @lst:docker-backend), према поступку из поглавља @docker: извршавање у `alpine` слици као непривилеговани корисник, са бинарним фајлом и јавним кључем. Приватни кључ уграђује само слика сервиса за кориснике. Сваки сервис носи сопствену `Dockerfile` датотеку, па се слике граде и објављују независно. Провера здравља позива одговарајућу руту сервера и пријављује исправност контејнера у току рада.

#figure(
```dockerfile
ARG RUST_VERSION=1.95
ARG APP_NAME=user-service
FROM rust:${RUST_VERSION}-alpine AS build
ARG APP_NAME
WORKDIR /app
RUN apk add --no-cache clang lld musl-dev git curl
RUN --mount=type=bind,source=services,target=services \
    --mount=type=bind,source=shared,target=shared \
    SQLX_OFFLINE=true cargo build --locked --release -p $APP_NAME \
    && cp ./target/release/$APP_NAME /bin/server
FROM alpine:3.24 AS final
RUN apk add --no-cache wget
RUN adduser --disabled-password --uid "10001" appuser
USER appuser
COPY --from=build /bin/server /bin/
COPY --chown=appuser:appuser keys/private.pem /keys/private.pem
COPY --chown=appuser:appuser keys/public.pem /keys/public.pem
HEALTHCHECK --interval=10s --timeout=5s --retries=10 \
    CMD wget -q -O /dev/null http://127.0.0.1:3005/api/user-service-health || exit 1
CMD ["/bin/server"]
```,
  caption: [Вишестепена слика серверског сервиса (скраћено из `user-service/Dockerfile`)]
) <lst:docker-backend>

Клијентска слика гради се алатом _Bun_ @bun2026, а сервира је непривилеговани _nginx_ на порту 8080, са адресом API _gateway_-а учитаном из окружења (листинг @lst:docker-frontend).

#figure(
```dockerfile
FROM oven/bun:1-alpine AS builder
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY angular.json tsconfig*.json ./
COPY src ./src
COPY public ./public
RUN bun run build
FROM nginxinc/nginx-unprivileged:1.31-alpine AS runner
ENV NGINX_ENVSUBST_FILTER=BACKEND_URL
COPY --chown=nginx:nginx nginx.conf /etc/nginx/templates/nginx.conf.template
COPY --chown=nginx:nginx --from=builder /app/dist/*/browser /usr/share/nginx/html
USER nginx
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
```,
  caption: [Слика клијентске апликације (скраћено из `playlog-frontend/Dockerfile`)]
) <lst:docker-frontend>

`Compose` датотеке описују апликативне и инфраструктурне контејнере заједно: сваки сервис прилаже сопствену датотеку, повезану заједничком мрежом `playlog_network`, са именованим волуменима за податке, при чему провере складишта (`pg_isready`, `mongosh ping`, _MinIO_ провера) задржавају покретање зависних сервиса.

Локално покретање користи `.env`, а покретање преко `Docker Compose`-a `.env.production`, са DNS именима контејнера уместо локалних адреса. `Makefile` нуди основне циљеве `start`, `stop` и `logs`, у заједничкој и појединачној варијанти (`start-user-service` и слично). Изградња (`build`, `rebuild`) је паралелна, а сервисни `Makefile`-ови додају `start-db` за саму базу и `start-dev` за зависности са чекањем на здравље. Пар кључева је претходно генерисан у фолдеру `playlog-backend/keys` и уграђује се при изградњи. Изложени портови су дати у табели @tbl:portovi: у продукцији само 8080, у развоју и портови складишта.

Ван контејнера, развојни _Angular_ клијент ради на порту `:4200`, а сервиси покренути командом `cargo` на портовима `:3000`-`:3005`.

#figure(
  caption: [Изложени портови по окружењу],
  table(
    columns: 4,
    align: (col, row) => (left, left, left, left).at(col),
    inset: 6pt,
    table.header(
    [*Контејнер*], [*Порт контејнера*], [*Мапирани порт (продукција)*], [*Мапирани порт (развој)*],
    ),
    [API _gateway_ сервис], [3000], [–], [–],
    [Сервис за каталог], [3001], [–], [–],
    [Сервис за библиотеку], [3002], [–], [–],
    [Сервис за мултимедију], [3003], [–], [–],
    [Сервис за кориснички садржај], [3004], [–], [–],
    [Сервис за кориснике], [3005], [–], [–],
    [Клијент], [8080], [8080], [–],
    [_PostgreSQL_ (3 базе)], [5432], [–], [5433-5435],
    [_MongoDB_ (2 базе)], [27017], [–], [27018-27019],
    [_MinIO_ (конзола 9001)], [9000], [–], [9000, 9001],
  )
) <tbl:portovi>