# 4. Images

Built by `platform.sh build` ([lib-images](scripts/lib-images.md)).

| Image | Dockerfile | Base | Runs as |
|---|---|---|---|
| `iam-platform/keycloak` | [`docker/keycloak/Dockerfile`](../docker/keycloak/Dockerfile) | `quay.io/keycloak/keycloak:26.8.2` | uid 1000 |
| `iam-platform/spring-app` | [`docker/spring-app/Dockerfile`](../docker/spring-app/Dockerfile) | `eclipse-temurin:25-jdk` → `25-jre` | uid 10001 |
| `iam-platform/test-client` | [`docker/test-client/Dockerfile`](../docker/test-client/Dockerfile) | `eclipse-temurin:25-jdk` → `25-jre` | uid 10001 |

## Staged build contexts

`build` does not use the repository as build context. For each image it
creates a self-contained directory:

```
build/context/keycloak/   Dockerfile  realm/  certs/{trust,tls,saml}/
build/context/app/        Dockerfile  apps/   certs/{trust,tls,saml}/
build/context/client/     Dockerfile  apps/   certs/{trust,tls,saml}/
```

Why:

- The context contains exactly what the image needs. Nothing else in your
  working tree (other certificates, `.git`, local config) can leak into a layer.
- The same directory works for `docker build` **and** for `az acr build`
  (`platform.sh push --acr-build`).
- The certificate material allowed by `CERT_MODE` is copied in explicitly;
  see [certificates](03-certificates-and-mtls.md#loading-certificates-into-images-cert_mode).

`apps/` is the Maven reactor without `target/` and without `src/test`
(tests run in `platform.sh verify`, not during image builds).
`platform.sh build --stage-only` stops after staging so you can inspect it.

The Dockerfiles use plain syntax only (no BuildKit-specific features) so they
also build with ACR Tasks.

## Keycloak image

Two stages, following Keycloak's recommendation for containers:

1. **builder** - sets the *build options*, copies the realm file and the CA,
   runs `kc.sh build` once.
2. **runtime** - copies the augmented server; starts with
   `start --optimized --import-realm`.

Build options are fixed at image build time and cannot be changed by
environment variables later:

| Build arg | From config | Effect |
|---|---|---|
| `KC_DB` | `KC_DB_VENDOR` | Database driver the server is optimised for. |
| `KC_HTTPS_CLIENT_AUTH` | `KC_HTTPS_CLIENT_AUTH` | `request` (default) or `required`. |
| - | fixed | `KC_HEALTH_ENABLED=true`, `KC_METRICS_ENABLED=true`, `KC_HTTPS_MANAGEMENT_CLIENT_AUTH=none` |

Changing the database vendor therefore means rebuilding the image
(`KC_DB_VENDOR=postgres platform.sh build --only keycloak`) and deploying
with the matching `keycloak.database.vendor`.

Baked into the image:

- `/opt/keycloak/data/import/platform-realm.json` - the [realm](05-keycloak-realm.md)
- `/opt/keycloak/conf/truststores/ca.crt` - the platform CA (`CERT_MODE=trust|baked`)

Everything else (hostname, certificate paths, database URL, admin
credentials, realm placeholders) is runtime configuration set by the chart.

## Spring app image

Three stages:

1. **build** - `./mvnw -pl spring-app -DskipTests package` with the Maven
   Wrapper inside the JDK image (needs Maven Central and the Shibboleth
   repository for OpenSAML).
2. **extract** - `java -Djarmode=tools … extract --layers`: splits the fat
   jar into dependencies / loader / snapshot dependencies / application, so
   a code change only replaces the small last layer.
3. **runtime** - JRE, unprivileged user `app` (10001), the layers, and the
   certificate material.

Entry point:

```
java -XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError -XX:+UseCompactObjectHeaders \
     -Djava.io.tmpdir=/tmp -jar application.jar
```

`-XX:+UseCompactObjectHeaders` is a Java 25 product flag that shrinks object
headers (less heap for the same data). Add your own flags with the
`JDK_JAVA_OPTIONS` environment variable (`app.javaOptions` in the chart).

The image works with a read-only root filesystem; only `/tmp` must be writable.

## Test client image

Two stages: package the jar, copy it onto a JRE. The client has no
third-party dependencies, so the image is a JRE plus one small jar.
Entry point `java … -jar test-client.jar`; arguments are passed through
(`--wait-only`, see [test client](07-test-client.md)).

## Labels

Every image gets OCI labels (`title`, `version`, `revision` = git commit,
`created`) and `io.platform.cert-mode`.

## Changing base images

Set `JAVA_BUILD_IMAGE` / `JAVA_RUNTIME_IMAGE` / `KEYCLOAK_BASE_IMAGE` in the
config, for example to the Microsoft Build of OpenJDK or to images mirrored
into your own registry (recommended for reproducible, rate-limit-free
builds). The Java Dockerfiles create their user with `useradd` or `adduser`,
whichever the base image has. For fully reproducible builds pin base images
by digest (`eclipse-temurin@sha256:…`).

## Linting

`platform.sh verify --only docker` runs hadolint with
[`.hadolint.yaml`](../.hadolint.yaml) on the three Dockerfiles.
