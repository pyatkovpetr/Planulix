package main

import "testing"

func TestExtractOAuthCodeFromPaste(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "url_with_query",
			in:   "http://localhost:33263/callback?code=AbC1&state=zzz",
			want: "AbC1",
		},
		{
			name: "bare_code_ampersand_state",
			in:   "AbC123&state=z_z",
			want: "AbC123",
		},
		{
			name: "query_blob_only",
			in:   "code=Wx%3D9&state=yyy",
			want: "Wx=9",
		},
		{
			name: "plain_code",
			in:   "Wx9abc",
			want: "Wx9abc",
		},
		{
			name: "success_url_with_id_token",
			in:   "http://localhost:1455/success?id_token=eyJ.h.e&needs_setup=false&org_id=",
			want: "eyJ.h.e",
		},
		{
			name: "id_token_query_blob",
			in:   "id_token=aa.bb.cc%2Bdd&needs_setup=false",
			want: "aa.bb.cc+dd",
		},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			got := extractOAuthCodeFromPaste(tt.in)
			if got != tt.want {
				t.Fatalf("extractOAuthCodeFromPaste(%q) = %q; want %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestAuthCodeFromInputPrefersCallback(t *testing.T) {
	got := authCodeFromInput("", "http://localhost/cb?code=fromCB&state=a")
	want := "fromCB"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	got2 := authCodeFromInput(" AbC789&state=ignore ", "")
	if got2 != "AbC789" {
		t.Fatalf("got %q want AbC789", got2)
	}
}

func TestAuthCodeFromInputIdToken(t *testing.T) {
	got := authCodeFromInput("", "http://localhost:1455/success?id_token=jwt-token-here&plan_type=prolite")
	if got != "jwt-token-here" {
		t.Fatalf("got %q want jwt-token-here", got)
	}
	// Prefer `code` when both appear (hypothetical).
	got2 := authCodeFromInput("", "http://localhost/c?code=X&id_token=Y")
	if got2 != "X" {
		t.Fatalf("got %q want X", got2)
	}
}
