# AEM Concepts Reference

> Loaded by the aem-local-dev skill when answering architecture or AEM-specific questions.

## AEMaaCS vs AEM 6.x

AEM as a Cloud Service (AEMaaCS) differs from on-premise AEM 6.x in key ways
relevant to local dev:

| Aspect | AEM 6.x | AEMaaCS |
|--------|---------|---------|
| Deployment | Customer-managed servers | Adobe-managed cloud |
| Local dev | Full AEM instance | SDK Quickstart (limited) |
| Persistence | TarMK / MongoMK | Cloud-native (Oak on cloud) |
| Config | Felix webconsole | OSGi config files in repo |
| Content | JCR repository | Same JCR model |
| Run modes | Flexible | `author`, `publish`, `local`, stage, prod |

The local SDK Quickstart **approximates** the cloud environment. Some cloud-only
features (Replication, Cloud Manager pipeline, CDN) are not available locally.

The SDK's required Java version moves with the cloud runtime: SDK 2026.x
quickstart refuses to start below **Java 21** (`JAVA_REQUIRED` in `.env`).

## Repository structure (Cloud Manager archetype)

```
my-aem-project/
├── core/                   # Java bundle — OSGi services, Sling models, servlets
│   └── src/main/java/
├── ui.apps/                # JCR content — components, templates, clientlibs
│   └── src/main/content/jcr_root/
├── ui.content/             # Mutable content — editable templates, policies
├── ui.config/              # OSGi config files (runmode-aware)
│   └── src/main/content/jcr_root/apps/.../osgiconfig/
│       ├── config/         # All run modes
│       ├── config.author/  # Author only
│       ├── config.publish/ # Publish only
│       └── config.local/   # Local dev only ← use this for dev overrides
├── ui.frontend/            # Webpack / clientlib build
├── dispatcher/
│   └── src/                # Dispatcher vhost + farm config
└── all/                    # Container package — deploys everything
```

## OSGi configuration files

OSGi configs in `ui.config` are `.cfg.json` files (preferred in AEMaaCS)
or `.config` files (legacy). They are deployed to the JCR and picked up by
Felix OSGi on startup.

```json
// ui.config/src/main/content/jcr_root/apps/my-app/osgiconfig/config.local/
// com.day.cq.replication.impl.ReplicationContentFactoryProviderImpl.cfg.json
{
  "enabled": true
}
```

Run mode suffixes on the folder (`config.author`, `config.publish`,
`config.local`) control which instance picks up the config.

## Sling models

```java
@Model(
    adaptables = Resource.class,
    adapters = MyModel.class,
    defaultInjectionStrategy = DefaultInjectionStrategy.OPTIONAL
)
public class MyModelImpl implements MyModel {
    @ValueMapValue
    private String title;

    @Override
    public String getTitle() { return title; }
}
```

Sling models live in `core/src/main/java`. They are adapted from `Resource`
or `SlingHttpServletRequest`. Always use `DefaultInjectionStrategy.OPTIONAL`
to avoid NPEs when properties are missing.

## HTL (Sightly) templates

HTL is AEM's server-side templating language. Files use `.html` extension
and live in `ui.apps/src/main/content/jcr_root/apps/`.

```html
<!--/* mycomponent/mycomponent.html */-->
<sly data-sly-use.model="com.myapp.core.models.MyModel">
    <div class="mycomponent">
        <h1>${model.title @ context='html'}</h1>
    </div>
</sly>
```

Key HTL rules:
- Always specify `context` on output (`text`, `html`, `uri`, `attributeName`)
- `data-sly-use` instantiates a Sling model or Java class
- `data-sly-list`, `data-sly-repeat` for iteration
- `data-sly-include`, `data-sly-resource` for composition

## Run modes explained

Run modes are labels applied at startup that control config loading and
behaviour. Comma-separated, e.g. `-r author,local`.

| Run mode | Purpose |
|----------|---------|
| `author` | Author instance — content creation, DAM, workflows |
| `publish` | Publish instance — content delivery to visitors |
| `local` | Developer-only. Config in `config.local/` only applies here |
| `dev` | Used in AEMaaCS cloud dev environments |
| `stage` / `prod` | Cloud-managed; never used locally |

The `local` run mode is the right place to put:
- Relaxed authentication (CRX DE access on publish)
- Debug logging configs
- Local-only OSGi service overrides

## Sling run mode config file naming

```
org.apache.sling.settings.SlingSettingsService.config

Content:
run.modes=["local"]
```

This file in `crx-quickstart/install/` tells the Sling Settings Service to
add `local` to the run modes on startup, even without passing `-r local`
on the command line. This project passes run modes with `-r` instead
(`AUTHOR_RUNMODE` / `PUBLISH_RUNMODE` in `.env`, used by `06-start-aem.sh`).

## Building and deploying to local AEM

```bash
# Full build + deploy to Author
mvn clean install -PautoInstallPackage

# Deploy to Publish
mvn clean install -PautoInstallPackagePublish

# Core bundle only (faster)
mvn clean install -PautoInstallBundle -pl core

# Frontend only
cd ui.frontend && npm run dev
```

## Useful AEM URLs (local)

```
# Author
http://localhost:4502/                          # Welcome screen
http://localhost:4502/crx/de/index.jsp          # CRXDE Lite
http://localhost:4502/system/console/bundles    # Felix OSGi console
http://localhost:4502/system/console/configMgr  # OSGi config manager
http://localhost:4502/libs/cq/core/content/welcome.html

# Publish
http://localhost:4503/                          # Publish root
http://localhost:4503/crx/de/index.jsp          # CRXDE on publish (local only)

# Via Dispatcher (HTTP, direct)
http://localhost:9999/
# Via nginx SSL → Dispatcher → Publish
https://dev-local-www-brand.com/

# End-to-end test page used in this project (WKND sample content installed)
https://dev-local-www-brand.com/content/wknd/us/en.html
```
