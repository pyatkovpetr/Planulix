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
