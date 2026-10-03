# Guarda Mídias

App independente para copiar fotos e vídeos do iPhone para `D:\Backup-Midias-iPhone`.

O app iOS lê fotos da biblioteca após permissão e arquivos salvos em **Arquivos > No Meu iPhone > Guarda Mídias**. Ele filtra por período e tamanho mínimo, envia cada original ao servidor Windows e compara o SHA-256 de ambos os lados. O servidor grava atomicamente, registra um comprovante e evita substituir arquivos diferentes com o mesmo nome.

O app não acessa a área privada do WhatsApp nem apaga mídia. Para mídias exclusivas do WhatsApp, primeiro use **Salvar em Fotos** ou **Salvar em Arquivos** e depois confira a cópia antes de excluir o original no WhatsApp.

## Servidor Windows

```powershell
py -3.12 -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe -m uvicorn app:app --host 0.0.0.0 --port 8765
```

O código de acesso fica em `D:\Backup-Midias-iPhone\.access-token` e nunca deve ser enviado a terceiros. O servidor aceita conexões HTTP na rede local, protegidas por esse código; para acesso remoto, use uma rede privada como Tailscale e prefira HTTPS.

## App iOS

O projeto em `ios/` usa XcodeGen. O fluxo de CI gera um IPA sem assinatura, que precisa ser assinado para instalar no iPhone.
