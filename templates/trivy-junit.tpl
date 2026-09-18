<?xml version="1.0" ?>
<testsuites name="trivy">
{{- range . -}}
    {{- $failures := len .Vulnerabilities }}
    {{- if gt $failures 0 }}
    <testsuite tests="{{ $failures }}" failures="{{ $failures }}" name="{{ .Target }} (Vulnerabilities)" errors="0" skipped="0" time="">
    {{- if not (eq .Type "") }}
        <properties>
            <property name="type" value="{{ .Type }}"></property>
        </properties>
    {{- end }}
    {{- range .Vulnerabilities }}
        <testcase classname="{{ .PkgName }}-{{ .InstalledVersion }}" name="[{{ .Vulnerability.Severity }}] {{ .VulnerabilityID }}" time="">
            <failure message="{{ escapeXML .Title }}" type="description">{{ escapeXML .Description }}</failure>
        </testcase>
    {{- end }}
    </testsuite>
    {{- end }}

    {{- $failures := len .Misconfigurations }}
    {{- if gt $failures 0 }}
    <testsuite tests="{{ $failures }}" failures="{{ $failures }}" name="{{ .Target }} (Misconfigurations)" errors="0" skipped="0" time="">
    {{- if not (eq .Type "") }}
        <properties>
            <property name="type" value="{{ .Type }}"></property>
        </properties>
    {{- end }}
    {{- range .Misconfigurations }}
        <testcase classname="{{ .Type }}" name="[{{ .Severity }}] {{ .AVDID }}" time="">
            <failure message="{{ escapeXML .Title }}" type="description">{{ escapeXML .Description }}</failure>
        </testcase>
    {{- end }}
    </testsuite>
    {{- end }}

    {{- $licenseFailures := 0 }}
    {{- range .Licenses }}
        {{- if ne .Severity "LOW" }}
            {{- $licenseFailures = add $licenseFailures 1 }}
        {{- end }}
    {{- end }}

    {{- if gt (len .Licenses) 0 }}
    <testsuite tests="{{ len .Licenses }}" failures="{{ $licenseFailures }}" name="{{ .Target }} (Licenses)" errors="0" skipped="0" time="">
    {{- if not (eq .Type "") }}
        <properties>
            <property name="type" value="{{ .Type }}"></property>
        </properties>
    {{- end }}
    {{- range .Licenses }}
        <testcase classname="{{ .Category }}" name="{{ .PkgName }}: {{ .Name }}" time="">
            <failure message="{{ .Name }} ({{ .Severity }})" type="{{ .Category }}">
PkgName: {{ .PkgName }}
License: {{ .Name }}
Category: {{ .Category }}
Severity: {{ .Severity }}
FilePath: {{ .FilePath }}
Confidence: {{ .Confidence }}
Link: {{ .Link }}
            </failure>
        </testcase>
    {{- end }}
    </testsuite>
    {{- end }}

{{- end }}
</testsuites>
