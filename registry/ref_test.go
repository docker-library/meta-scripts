package registry_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/docker-library/meta-scripts/registry"

	"cuelabs.dev/go/oci/ociregistry/ociref"
)

func toJson(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal("unexpected JSON error", err)
	}
	return string(b)
}

func fromJson(t *testing.T, j string, v any) {
	t.Helper()
	err := json.Unmarshal([]byte(j), v)
	if err != nil {
		t.Fatal("unexpected JSON error", err)
	}
}

func TestParseRef(t *testing.T) {
	t.Parallel()

	for _, o := range []struct {
		in  string
		out string
	}{
		{"hello-world:latest", "docker.io/library/hello-world:latest"},
		{"tianon/true:oci", "docker.io/tianon/true:oci"},
		{"docker.io/tianon/true:oci", "docker.io/tianon/true:oci"},
		{"localhost:5000/foo", "localhost:5000/foo"},

		// Docker Hub edge cases
		{"hello-world", "docker.io/library/hello-world"},
		{"library/hello-world", "docker.io/library/hello-world"},
		{"docker.io/hello-world", "docker.io/library/hello-world"},
		{"docker.io/library/hello-world", "docker.io/library/hello-world"},
		{"index.docker.io/library/hello-world", "docker.io/library/hello-world"},
		{"registry-1.docker.io/library/hello-world", "docker.io/library/hello-world"},
		{"registry.hub.docker.com/library/hello-world", "docker.io/library/hello-world"},
	} {
		o := o // https://github.com/golang/go/issues/60078
		dockerOut := strings.TrimPrefix(strings.TrimPrefix(o.out, "docker.io/library/"), "docker.io/")

		t.Run(o.in, func(t *testing.T) {
			ref, err := registry.ParseRef(o.in)
			if err != nil {
				t.Fatal("unexpected error", err)
			}

			out := ociref.Reference(ref).String()
			if out != o.out {
				t.Fatalf("expected %q, got %q", o.out, out)
			}

			out = ref.String()
			if out != dockerOut {
				t.Fatalf("expected %q, got %q", dockerOut, out)
			}
		})

		t.Run(o.in+" JSON", func(t *testing.T) {
			json := toJson(t, o.in) // "hello-world:latest" (string straight to JSON so we can unmarshal it as a Reference)
			var ref registry.Reference
			fromJson(t, json, &ref)
			out := ociref.Reference(ref).String()
			if out != o.out {
				t.Fatalf("expected %q, got %q", o.out, out)
			}

			json = toJson(t, ref)   // "hello-world:latest" (take our reference and convert it to JSON so we can verify it goes out correctly)
			fromJson(t, json, &out) // back to a string
			if out != dockerOut {
				t.Fatalf("expected %q, got %q", dockerOut, out)
			}
		})
	}
}
