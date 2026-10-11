# Bibliotecas de modelos no Snapmaker Orca 2.3.6

Esta versão de teste amplia a aba MakerWorld existente para cinco bibliotecas:
MakerWorld, Printables (Prusa), Thingiverse, MyMiniFactory e Cults3D. A seleção
carrega cada página em uma WebView sem a ponte nativa privilegiada usada pela
interface de dispositivos. Há botões para voltar, avançar, ir ao início,
recarregar, abrir a página no navegador padrão e importar um arquivo local.

No MakerWorld, os links `bambustudio://` e `bambustudioopen://` continuam
validados e encaminhados ao importador existente. Nas outras bibliotecas,
baixe um arquivo 3MF/STL/STEP/SVG/OBJ/AMF no navegador e use **Import downloaded
file**. Não há login compartilhado entre sites nem importação automática de
links de terceiros. Algumas páginas ou fluxos de login podem não funcionar na
WebView; **Open in browser** é a alternativa. Nenhuma ação inicia impressão.

## Atualizações e perfil de teste

A verificação de atualizações permanece ativa. Antes de abrir a página de
download de uma atualização oficial, o aplicativo avisa que um instalador
oficial pode substituir a personalização. Um aviso também aparece no diálogo
de atualização obrigatória, sem impedir o fluxo obrigatório do aplicativo.
Uma versão oficial sem este código não terá a aba de bibliotecas; para manter a
integração, reaplique as alterações ao código da nova versão, compile e valide
um novo pacote personalizado antes de trocar o executável de teste.

O executável portátil instalado corresponde ao commit
`8197c32967b801a7c6fbc85dcd48599fcc5a03a9`. O perfil é isolado pelo
argumento `--datadir` do atalho de teste. A correção local da câmera em
`perfil-teste-makerworld/web/flutter_web/index.html` não faz parte do código
fonte desta mudança: preserve esse perfil e compare o arquivo após qualquer
atualização dos recursos web antes de reaplicar a correção. Não copie arquivos
de configuração ou credenciais do perfil para o repositório.

## Verificação antes de usar

1. Compilar em uma instalação Windows com Visual Studio 2022 Desktop C++,
   Windows SDK, CMake, Perl e as dependências do projeto. Seguir
   `build_release_vs2022.bat` em diretório de saída separado.
2. Executar `tests/makerworld/test_links.cpp` pelo CMake de
   `tests/makerworld/`. Esse teste cobre URLs e domínios, mas não substitui
   teste da interface.
3. Abrir a build em um perfil `--datadir` exclusivo. Confirmar seleção,
   navegação e abertura externa das cinco bibliotecas, inclusive volta/avanço.
4. Importar um 3MF de MakerWorld pelo link nativo e um STL/3MF baixado de outra
   biblioteca pelo botão de arquivo. Testar cancelamento do diálogo de arquivo.
5. Confirmar que o alerta de atualização continua visível e que cancelar a
   abertura da página oficial não altera a instalação. Conferir a câmera no
   perfil de teste; não iniciar impressão durante essa validação.

Depois de qualquer importação, selecione a U1 e revise bico, materiais, cores,
suportes e fatiamento. O programa não converte automaticamente perfis de outras
impressoras para a U1.
