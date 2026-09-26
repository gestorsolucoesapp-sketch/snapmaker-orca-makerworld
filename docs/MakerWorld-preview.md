# MakerWorld dentro do Snapmaker Orca 2.3.6 — protótipo

Esta alteração adiciona uma aba nativa MakerWorld, com navegação e encaminhamento
dos links “Abrir no Bambu Studio” para o importador do Snapmaker Orca.

**Estado: código implementado; compilação completa e teste na interface pendentes.**
Os testes independentes verificam a validação dos links; não comprovam login,
download real, importação de um projeto ou fatiamento dentro da interface.

Base exata: Snapmaker/OrcaSlicer, tag v2.3.6,
commit 5417538a1c47d64d57b0401c095f40d1bcd7c9da.

## Comportamento implementado

- Aba MakerWorld dentro da janela principal, carregada quando aberta.
- Início em https://makerworld.com/pt; voltar, avançar, recarregar e opção de
  abrir a página no navegador externo em caso de incompatibilidade do site.
- Links bambustudio:// e bambustudioopen:// são tratados dentro do aplicativo.
- O importador existente baixa/abre o projeto; a aba não envia uma impressão.
- Diálogo existente de salvamento antes de substituir um projeto alterado.
- Escolha da pasta de downloads se nenhuma pasta válida estiver configurada.
- Nenhuma mudança nas associações do Windows ou nos perfis de impressora.
- Navegador público sem a ponte de comandos privilegiados da interface Snapmaker.

Depois de importar, selecionar U1, conferir bico, materiais, cores, suportes e
configurações, e fatiar novamente. A adaptação automática de perfis Bambu à U1 não
faz parte desta alteração. Compatibilidade entre versões de 3MF continua sujeita
ao importador original.

## Compilar

No Windows, o projeto original precisa de Visual Studio 2022 com desenvolvimento
desktop C++, Windows SDK, CMake e Perl, além das dependências compiladas do Orca.
Reservar espaço para dependências e arquivos intermediários; uma compilação completa exige espaço livre para ferramentas, dependências e artefatos.

O fluxo `.github/workflows/makerworld-windows.yml` foi preparado para execução
manual em um repositório GitHub com estas alterações. Ele testa os links,
compila dependências e aplicativo e guarda um artefato portátil. Não publica
release e não envia código a outro repositório. Na primeira execução, aplica o
pacote de alterações e salva o código-fonte neste mesmo repositório antes de
compilar. Consulte a aba Actions para o resultado de cada execução.
Custos e limites dependem da conta GitHub usada.

Para testes independentes, sem dependências do fatiador:

```powershell
cmake -S tests/makerworld -B build-link-tests
cmake --build build-link-tests --config Release
ctest --test-dir build-link-tests -C Release --output-on-failure
```

Para a aplicação, seguir `build_release_vs2022.bat` e a configuração explícita
do workflow. Não substituir a instalação de uso diário antes da validação.
O nome/base de configurações do programa continua sendo o original: uma build
portátil não equivale a um perfil de usuário isolado. Para teste independente,
usar uma conta Windows de teste ou o argumento `--datadir` do aplicativo com uma
pasta exclusiva e sem credenciais/configurações de produção.

## Verificação manual obrigatória após compilar

1. Iniciar a build de teste; confirmar abas Preparar, Prévia e Dispositivo.
2. Abrir MakerWorld; validar carregamento, pesquisa, modelo, voltar e avançar.
3. Fazer login se necessário; validar se o site aceita o navegador embutido.
   Popups de autenticação são abertos na mesma vista; fluxos dependentes de
   outra janela podem exigir adaptação. Não contornar desafios do site.
4. Abrir um 3MF pelo botão do MakerWorld; conferir pintura e objetos importados.
5. Repetir com um projeto alterado e cancelar o diálogo de salvamento: o projeto
   anterior deve permanecer. Repetir sem uma pasta de downloads configurada.
6. Selecionar U1, atribuir os materiais e fatiar; conferir a prévia sem imprimir.
7. Verificar que o botão externo do MakerWorld continua abrindo o Bambu Studio
   quando essa associação já existia no Windows.
8. Trocar entre perfis de impressora e verificar as abas, inclusive Calibração.

Limitações a verificar: proteção anti-bot, cookies/login em WebView2, mudanças
nos formatos de links/CDNs e eventuais incompatibilidades de 3MF. O botão de
download comum do site não é interceptado: usar “Abrir no Bambu Studio”.

## Licença

Alteração sobre projeto AGPL-3.0. Ao distribuir uma build modificada, fornecer
também o código-fonte correspondente conforme `LICENSE.txt`. Esta é uma
customização independente, sem afiliação oficial com Snapmaker ou Bambu Lab.
