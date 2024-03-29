package om_test

import (
	"encoding/json"
	"strconv"
	"testing"

	"github.com/docker-library/meta-scripts/om"
)

func BenchmarkSet(b *testing.B) {
	var m om.OrderedMap[int]
	for i := 0; i < b.N; i++ {
		m.Set(strconv.Itoa(i), i)
	}
}

func assert[V comparable](t *testing.T, v V, expected V) {
	t.Helper()
	if v != expected {
		t.Fatalf("expected %v, got %v", expected, v)
	}
}

func assertJSON[V any](t *testing.T, v V, expected string) {
	t.Helper()
	b, err := json.Marshal(v)
	assert(t, err, nil)
	assert(t, string(b), expected)
}

func TestOrderedMapSet(t *testing.T) {
	var m om.OrderedMap[string]
	assertJSON(t, m, `{}`)
	m.Set("c", "a")
	assert(t, m.Get("c"), "a")
	assert(t, m.Get("b"), "")
	assertJSON(t, m, `{"c":"a"}`)
	m.Set("b", "b")
	assertJSON(t, m, `{"c":"a","b":"b"}`)
	m.Set("a", "c")
	assertJSON(t, m, `{"c":"a","b":"b","a":"c"}`)
	m.Set("c", "d")
	assert(t, m.Get("c"), "d")
	assertJSON(t, m, `{"c":"d","b":"b","a":"c"}`)
	keys := m.Keys()
	assert(t, len(keys), 3)
	assert(t, keys[0], "c")
	assert(t, keys[1], "b")
	assert(t, keys[2], "a")
	keys[0] = "d" // make sure the result of .Keys cannot modify the original
	keys = m.Keys()
	assert(t, keys[0], "c")
}

func TestOrderedMapUnmarshal(t *testing.T) {
	var m om.OrderedMap[string]
	assert(t, json.Unmarshal([]byte(`{}`), &m), nil)
	assertJSON(t, m, `{}`)
	assert(t, json.Unmarshal([]byte(`{ "foo" : "bar" }`), &m), nil)
	assertJSON(t, m, `{"foo":"bar"}`)
	assert(t, json.Unmarshal([]byte(`{ "baz" : "buzz" }`), &m), nil)
	assertJSON(t, m, `{"foo":"bar","baz":"buzz"}`)
	assert(t, json.Unmarshal([]byte(`{ "foo" : "foo" }`), &m), nil)
	assertJSON(t, m, `{"foo":"foo","baz":"buzz"}`)
}

func TestOrderedMapUnmarshalDupes(t *testing.T) {
	var m om.OrderedMap[string]
	assert(t, json.Unmarshal([]byte(`{ "foo":"foo", "bar":"bar", "foo":"baz" }`), &m), nil)
	assertJSON(t, m, `{"foo":"baz","bar":"bar"}`)
}
