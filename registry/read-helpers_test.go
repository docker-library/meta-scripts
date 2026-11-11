package registry

import (
	"strings"
	"testing"

	"cuelabs.dev/go/oci/ociregistry"
	"cuelabs.dev/go/oci/ociregistry/ocimem"
	godigest "github.com/opencontainers/go-digest"
)

func TestReadJSONHelper(t *testing.T) {
	t.Parallel()

	for _, o := range []struct {
		name string
		data string

		// optional tweaks to the (otherwise correct) descriptor of "data"
		sizeDelta int64
		digest    godigest.Digest

		wantErr string
	}{
		{name: "exact", data: `{"a":1}`},
		{name: "trailing newline", data: "{\"a\":1}\n"},
		{name: "leading and trailing whitespace", data: " \n\t{\"a\":1}\r\n \n"},

		// the decoder buffers ahead, so anything after the object is already in its buffer by the time we go looking for "leftovers" (and used to go completely unchecked)
		{name: "trailing garbage", data: `{"a":1} x`, wantErr: "unexpected non-whitespace"},
		{name: "trailing second object", data: `{"a":1}{"a":2}`, wantErr: "unexpected non-whitespace"},
		{name: "trailing garbage after whitespace", data: "{\"a\":1}\n\n x\n", wantErr: "unexpected non-whitespace"},

		{name: "invalid json", data: `{"a":`, wantErr: "unexpected EOF"},
		{name: "wrong type", data: `{"a":"b"}`, wantErr: "cannot unmarshal"},

		// descriptor lies about the object
		{name: "size too big", data: `{"a":1}`, sizeDelta: 1, wantErr: "smaller than it should be"},
		{name: "size too small", data: "{\"a\":1}\n\n\n", sizeDelta: -3, wantErr: "bigger than it should be"},
		{name: "wrong digest", data: `{"a":1}`, digest: godigest.FromString("not the right data"), wantErr: "not correct"},
		{name: "invalid digest", data: `{"a":1}`, digest: "not-a-digest", wantErr: "invalid checksum digest format"},
	} {
		o := o // https://github.com/golang/go/issues/60078 (go.mod is still "go 1.21")

		t.Run(o.name, func(t *testing.T) {
			t.Parallel()

			desc := ociregistry.Descriptor{
				Digest: godigest.FromString(o.data),
				Size:   int64(len(o.data)) + o.sizeDelta,
			}
			if o.digest != "" {
				desc.Digest = o.digest
			}

			var v struct {
				A int `json:"a"`
			}
			err := readJSONHelper(ocimem.NewBytesReader([]byte(o.data), desc), &v)

			if o.wantErr == "" {
				if err != nil {
					t.Fatal("unexpected error", err)
				}
				if v.A != 1 {
					t.Errorf("unexpected value: %+v", v)
				}
				return
			}

			if err == nil {
				t.Fatalf("expected error containing %q, got nil", o.wantErr)
			}
			if !strings.Contains(err.Error(), o.wantErr) {
				t.Errorf("expected error containing %q, got %q", o.wantErr, err)
			}
		})
	}
}
