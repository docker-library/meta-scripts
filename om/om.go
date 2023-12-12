package om

// https://github.com/golang/go/issues/27179

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// only supports string keys because JSON is the intended use case (and the JSON spec says only string keys are allowed)
type OrderedMap[T any] struct {
	m    map[string]T
	keys []string
}

func (m OrderedMap[T]) Keys() []string {
	return append([]string{}, m.keys...)
}

func (m OrderedMap[T]) Get(key string) T {
	return m.m[key]
}

// TODO Has()?  two-return form of Get?  (we don't need either right now)

func (m *OrderedMap[T]) Set(key string, val T) { // TODO make this variadic so it can take an arbitrary number of pairs?  (would be useful for tests, but we don't need something like that right now)
	if m.m == nil || m.keys == nil {
		m.m = map[string]T{}
		m.keys = []string{}
	}
	if _, ok := m.m[key]; !ok {
		m.keys = append(m.keys, key)
	}
	m.m[key] = val
}

func (m *OrderedMap[T]) UnmarshalJSON(b []byte) error {
	dec := json.NewDecoder(bytes.NewReader(b))

	// read opening {
	if tok, err := dec.Token(); err != nil {
		return err
	} else if tok != json.Delim('{') {
		return fmt.Errorf("expected '{', got %T: %#v", tok, tok)
	}

	for {
		tok, err := dec.Token()
		if err != nil {
			return err
		}
		if tok == json.Delim('}') {
			break
		}
		key, ok := tok.(string)
		if !ok {
			return fmt.Errorf("expected string key, got %T: %#v", tok, tok)
		}
		var val T
		err = dec.Decode(&val)
		if err != nil {
			return err
		}
		m.Set(key, val)
	}

	if dec.More() {
		return fmt.Errorf("unexpected extra content after closing '}'")
	}

	return nil
}

func (m OrderedMap[T]) MarshalJSON() ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	if err := buf.WriteByte('{'); err != nil {
		return nil, err
	}
	for i, key := range m.keys {
		if i > 0 {
			buf.WriteByte(',')
		}
		if err := enc.Encode(key); err != nil {
			return nil, err
		}
		buf.WriteByte(':')
		if err := enc.Encode(m.m[key]); err != nil {
			return nil, err
		}
	}
	if err := buf.WriteByte('}'); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
