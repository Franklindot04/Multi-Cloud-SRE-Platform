package platform

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Env reads validated settings from environment variables and collects every problem,
// so a bad configuration is reported in one go.
type Env struct {
	lookup func(string) (string, bool)
	errs   []error
}

// NewEnv reads from the process environment.
func NewEnv() *Env { return &Env{lookup: os.LookupEnv} }

// NewEnvFrom reads from a map, for tests.
func NewEnvFrom(m map[string]string) *Env {
	return &Env{lookup: func(k string) (string, bool) { v, ok := m[k]; return v, ok }}
}

func (e *Env) fail(format string, args ...any) { e.errs = append(e.errs, fmt.Errorf(format, args...)) }

// String returns the variable or def when unset or empty.
func (e *Env) String(key, def string) string {
	if v, ok := e.lookup(key); ok && strings.TrimSpace(v) != "" {
		return strings.TrimSpace(v)
	}
	return def
}

// Secret returns the value of KEY, or the trimmed content of the file named by KEY_FILE (a mounted
// secret). Setting both is an error, and so is an unreadable or empty file. It returns "" when neither is
// set and required is false; when required is true that is an error too.
func (e *Env) Secret(key string, required bool) string {
	value, hasValue := e.lookup(key)
	path, hasFile := e.lookup(key + "_FILE")
	value, path = strings.TrimSpace(value), strings.TrimSpace(path)
	hasValue, hasFile = hasValue && value != "", hasFile && path != ""
	switch {
	case hasValue && hasFile:
		e.fail("%s and %s_FILE are both set; use one", key, key)
	case hasFile:
		b, err := os.ReadFile(path)
		content := strings.TrimSpace(string(b))
		if err != nil || content == "" {
			e.fail("%s_FILE cannot be read or is empty: %s", key, path)
			return ""
		}
		return content
	case hasValue:
		return value
	case required:
		e.fail("%s or %s_FILE is required", key, key)
	}
	return ""
}

// Int returns an integer in [min, max].
func (e *Env) Int(key string, def, min, max int) int {
	v, ok := e.lookup(key)
	if !ok || strings.TrimSpace(v) == "" {
		return def
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || n < min || n > max {
		e.fail("%s must be an integer between %d and %d, got %q", key, min, max, v)
		return def
	}
	return n
}

// Float returns a number in [min, max].
func (e *Env) Float(key string, def, min, max float64) float64 {
	v, ok := e.lookup(key)
	if !ok || strings.TrimSpace(v) == "" {
		return def
	}
	n, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
	if err != nil || n < min || n > max {
		e.fail("%s must be a number between %g and %g, got %q", key, min, max, v)
		return def
	}
	return n
}

// Bool returns a boolean ("true" or "false").
func (e *Env) Bool(key string, def bool) bool {
	v, ok := e.lookup(key)
	if !ok || strings.TrimSpace(v) == "" {
		return def
	}
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "true":
		return true
	case "false":
		return false
	}
	e.fail("%s must be true or false, got %q", key, v)
	return def
}

// URL returns an http(s) URL without a trailing slash.
func (e *Env) URL(key, def string) string {
	v := strings.TrimRight(e.String(key, def), "/")
	if !strings.HasPrefix(v, "http://") && !strings.HasPrefix(v, "https://") {
		e.fail("%s must start with http:// or https://, got %q", key, v)
	}
	return v
}

// OneOf returns a value that must be in allowed.
func (e *Env) OneOf(key, def string, allowed ...string) string {
	v := e.String(key, def)
	for _, a := range allowed {
		if v == a {
			return v
		}
	}
	e.fail("%s must be one of %s, got %q", key, strings.Join(allowed, ", "), v)
	return def
}

// Err returns all collected problems, or nil.
func (e *Env) Err() error { return errors.Join(e.errs...) }
