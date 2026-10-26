# sonarqube

| Workflow · Job | Description |
| --- | --- |
| `sonarqube.yml` · `scanner-image` | Resolves the scanner container, `SONAR_SCANNER_IMAGE` in the primary image registry. |
| `sonarqube.yml` · `sonarqube` | Runs in the SonarSource scanner container. Fetches full history (Sonar attributes issues to authors and measures new code against a baseline), downloads any `*-test-reports` artifacts for coverage, and waits on the quality gate. A monorepo child analyses as its own project, keyed by its subpath. |

[Documentation index](../../README.md)
