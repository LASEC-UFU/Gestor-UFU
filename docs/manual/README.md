# Manual do Gestor UFU

- Site estático: `site/`
- Página inicial local: `site/index.html`
- Inventário e checklist: `INVENTARIO.md`
- Capturas: `site/assets/screenshots/`
- Índice da busca: `site/search-index.json`
- Publicação: `.github/workflows/pages.yml`

Para pré-visualizar, sirva `docs/manual/site` com um servidor HTTP estático (por exemplo, `python -m http.server 8000 --directory docs/manual/site`) e abra `http://localhost:8000`. A busca usa `fetch`, portanto não deve ser validada abrindo o arquivo HTML diretamente como `file://`.

Quando a documentação mudar, revise os nomes/fluxos no código e na versão em execução, substitua as capturas por screenshots reais de uma instalação de demonstração e atualize a data, versão e commit tanto no início do site quanto no inventário. Mantenha os dados fictícios e não publique credenciais, arquivos de backup nem processos reais.

O workflow publica a pasta `docs/manual/site` no GitHub Pages. A primeira ativação pode exigir que um administrador escolha **Settings → Pages → Build and deployment → GitHub Actions** no repositório. O endereço só deve ser divulgado como publicado após sucesso do job de deploy.
