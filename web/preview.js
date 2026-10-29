window.STRM_CONFIG = {
  apiUrl: "http://127.0.0.1:8765",
  clientId: "preview",
  cognitoDomain: "http://127.0.0.1:8765",
};
sessionStorage.setItem("strm_tokens", JSON.stringify({ id_token: "preview" }));
window.renderStatements(document.getElementById("app"), {
  name: "preview@example.com",
  embedded: false,
  logout() {
    sessionStorage.removeItem("strm_tokens");
    window.location.reload();
  },
});
