# sonarqube

| Workflow · Job | Description |
| --- | --- |
| `sonarqube.yml` · `sonarqube` | Runs in the SonarSource scanner container (`sonarsource/sonar-scanner-cli:12.4.0.4321_8.4.0` unless `SONAR_SCANNER_IMAGE` is set). Fetches full history (Sonar attributes issues to authors and measures new code against a baseline), downloads any `*-test-reports` artifacts for coverage, and waits on the quality gate. A monorepo child analyses as its own project, keyed by its subpath. |

[Documentation index](../../README.md)
