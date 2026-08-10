# Backups

Cópias de estado que vive fora do repositório (configurações do app, em
`~/.omniomics.json`), guardadas aqui antes de qualquer operação destrutiva.

| Arquivo | O que é |
|---|---|
| `omniomics-settings-2026-08-10.json` | Configurações do app antes de apagar as runs antigas do MAGMA. Contém `conda_path`, diretórios de banco, rascunhos de execução, e as listas `runs` e `plot_runs`. |
| `omniomics-settings-2026-08-10-arquivo-com-parenteses.json` | Resquício do bug em que `SETTINGS_FILE` apontava para `~/.omniomics.json()`. Foi escrito na janela em que o bug esteve ativo; o arquivo correto é mais recente e mais completo. Guardado por precaução, não é para ser restaurado. |
| `omniomics-settings-2026-08-10-apos-nova-run.json` | Depois de remover as 2 runs MAGMA registradas (e 39 `plot_runs` órfãos) e registrar `magma-testrun-12s-9mags`. |
