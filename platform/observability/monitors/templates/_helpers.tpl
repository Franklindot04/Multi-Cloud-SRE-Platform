{{- /* The expression for an SLO ratio or count: the placeholders replaced by the function (rate or increase) and the window. */ -}}
{{- define "slo.expr" -}}
{{- .expr | replace "__FN__" .fn | replace "__WINDOW__" .window -}}
{{- end -}}
