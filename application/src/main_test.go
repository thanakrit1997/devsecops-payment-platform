package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestProbeEndpoints(t *testing.T) {
	t.Setenv("APP_ENV", "test")
	srv := httptest.NewServer(newMux())
	defer srv.Close()

	for path, want := range map[string]response{
		"/health": {Status: "ok"},
		"/ready":  {Status: "ready", Env: "test"},
	} {
		res, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		var got response
		if err := json.NewDecoder(res.Body).Decode(&got); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		res.Body.Close()
		if res.StatusCode != http.StatusOK || got != want {
			t.Errorf("%s: status %d body %+v, want 200 %+v", path, res.StatusCode, got, want)
		}
		if ct := res.Header.Get("Content-Type"); ct != "application/json" {
			t.Errorf("%s: Content-Type %q", path, ct)
		}
	}

	if res, _ := http.Get(srv.URL + "/does-not-exist"); res.StatusCode != http.StatusNotFound {
		t.Errorf("unknown path: status %d, want 404", res.StatusCode)
	}
}
