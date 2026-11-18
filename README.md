# Vortex software factory

A skeleton for an agentic software factory on GitHub Actions with [Sonar Vortex](https://www.sonarsource.com/blog/introducing-sonar-vortex/) built in. Label an issue `factory:run`; an agent implements it on an ephemeral runner, Vortex guides and checks the work, a separate job opens the pull request, and the SonarQube Cloud quality gate decides whether a human can merge.

There is no application code here. Copy the files into your repository.

## Tiers

| Tier | Where | Holds | Cannot |
| --- | --- | --- | --- |
| Intake | `factory.yml` job `intake` | `issues: read` | write anything |
| Worker | job `worker`, environment `factory-worker` | Claude token, SonarQube user token, `contents: read` | push, open PRs, edit `ctl/` |
| Publisher | job `publish`, environment `factory-publish` | factory GitHub App token (no workflows permission) | run the model, read Sonar or Claude secrets |
| Verifier | `ci.yml` on `pull_request` and `push: main` | `SONAR_TOKEN` | be edited by the agent |
| Merge | a human, under the `main` ruleset | their own identity | n/a |

The worker checks out the base commit twice: `ws/` is the agent's project, `ctl/` holds the scripts and stays outside it. The agent leaves a patch; the publisher verifies its SHA-256, rejects protected paths and edits to analysis or coverage configuration, applies it on the base commit, and pushes as the App.

## Requirements

- SonarQube Cloud on an [Enterprise plan or annual Team plan](https://www.sonarsource.com/plans-and-pricing/sonarcloud/) with Vortex enabled for the organization, and Architecture analysis if you want `get-constraints` to return anything.
- The project analyzed in CI on its default branch (`ci.yml` does this) with automatic analysis off. Vortex restores analyzer context from that analysis.
- A GitHub plan that supports environments with secrets and rulesets on your repository.

## Set up

1. Copy `.github/`, `tests/`, and `.sonar-config.json` into your repository. Create the SonarQube Cloud project, then run `sonar link <project-key>` to generate `.sonar-config.json`.
2. Set `SONAR_CLI_SHA256` in `.github/factory/versions.env` (`shasum -a 256` of the pinned Linux x64 binary from `binaries.sonarsource.com`). The workflow refuses to run without it.
3. Add the secrets and variables below.
4. Create the GitHub App, install it on this repository only, and set `FACTORY_APP_CLIENT_ID` and `FACTORY_APP_PRIVATE_KEY`.
5. Edit `.github/CODEOWNERS`. Push to the default branch so `ci.yml` analyzes it, then open one ordinary pull request so the SonarQube Cloud GitHub app reports on it. Don't import the ruleset yet.
6. Import `.github/rulesets/main.json` (Settings > Rules > Rulesets > Import). It requires two checks: `Build` from `ci.yml` and `SonarCloud Code Analysis`, which the SonarQube Cloud GitHub app posts (integration ID 12526). A required check that has never reported leaves every pull request waiting, which is why the import comes after that first analysis. If you import earlier, add the SonarQube Cloud check to the ruleset's required checks by hand once it appears.
7. File an issue and add the `factory:run` label.

| Name | Kind | Scope | Value |
| --- | --- | --- | --- |
| `ANTHROPIC_API_KEY` | secret | environment `factory-worker` | Anthropic API key, or your LLM gateway's placeholder key |
| `ANTHROPIC_BASE_URL`, `ANTHROPIC_CUSTOM_HEADERS` | secret (optional) | environment `factory-worker` | only when model traffic goes through an LLM gateway |
| `SONARQUBE_CLI_TOKEN` | secret | environment `factory-worker` | SonarQube Cloud **user** token (project, global, and scoped organization tokens don't work for Vortex) |
| `SONARQUBE_CLI_ORG` | variable | environment `factory-worker` | organization key |
| `FACTORY_APP_PRIVATE_KEY` | secret | environment `factory-publish` | App private key |
| `FACTORY_APP_CLIENT_ID` | variable | environment `factory-publish` | App client ID |
| `SONAR_TOKEN` | secret | repository | scoped organization token: specific projects, Execute analysis and Browse |

The worker's user token is readable by the agent, so give it a short expiry. Transcripts in the `factory-evidence` artifact contain everything the agent saw; restrict who can download artifacts.

**App permissions:** Contents (read and write), Pull requests (read and write), Issues (read and write), Metadata (read). No Workflows permission: GitHub then refuses any push that touches `.github/workflows`. Push with an App token, not `GITHUB_TOKEN`, so `ci.yml` runs on the pull request.

## Swap points

Gradle is the worked example. Two places change for another build tool:

- **Toolchain:** the JDK and cache steps in `ci.yml` (swap point 1) and `.github/actions/setup-toolchain/action.yml`.
- **Build and analyze:** the last step of `ci.yml` and the `Warm the build` step in `factory.yml` (swap point 2). The SonarQube Cloud docs have the [Maven, .NET, and scan-action variants](https://docs.sonarsource.com/sonarqube-cloud/analyzing-source-code/ci-based-analysis/github-actions-for-sonarcloud/).

Then set `TEST_CMD`, `AGENT_BUILD_TOOLS`, `SOURCE_REGEX`, and `VORTEX_WARMUP_ECOSYSTEM` in `factory.env`, the build-file lines in `gate-guard.txt`, and the build files in `CODEOWNERS`.

## What the agent sees

`prompt.md` is the issue title and body plus one generic instruction. It says nothing about Sonar. Vortex reaches the agent only through what `sonar integrate claude` installs (the session-start context and the per-edit hook) and through the factory's own DEEP check after each round. Only findings on lines the agent added or changed (`git diff --unified=0` against `BASE_SHA`, plus new files in full) go back to the agent in a resumed session, up to `MAX_REPAIR` times. Findings elsewhere in the touched files are kept in the evidence as pre-existing. A repeated set of findings, a skipped or failed file, or a changed source file missing from the result stops the run as `unresolved` or `error`, never as clean.

Each run uploads `factory-evidence`: raw transcripts, test logs, Vortex results, and `summary.json` with the session-start context and every `sonar context` and `sonar analyze agentic` call read from the transcript.

## Test

```bash
bash tests/run.sh
```

Covers the findings filter, the verify exit-code mapping (with a stub `sonar`), the publisher's path denylist and gate guard, and the evidence summary. Lint with `shellcheck -x -P SCRIPTDIR .github/factory/*.sh tests/*.sh` and `actionlint`.

## License

MIT
