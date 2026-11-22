# Paridade com o SimpMusic original (Android)

Tirada do código (telas em `composeApp/.../ui/screen`, opções de `SettingScreen.kt`, estilos em
`player/content`). K = versão Kotlin no iPhone, S = versão Swift. `[x]` feito, `[ ]` falta,
`[—]` impossível no iPhone (motivo ao lado), `[?]` depende do usuário.

## Telas
| Tela | K | S |
|---|---|---|
| Início (carrosséis, chips, Mood) | [x] | [x] |
| Busca (abas, sugestões, histórico) | [x] | [x] |
| Biblioteca (playlists, curtidas, baixadas, chips) | [x] | [x] |
| Biblioteca: aba Wrapped + recap mensal | [x] | [ ] |
| Mix para você (MixForYouScreen) | [x] | [ ] |
| Playlists dinâmicas da biblioteca | [x] | [ ] |
| Playlist local (editar, IA sugerir) | [x] | [ ] parcial |
| Álbum / Playlist / Artista (cabeçalho imersivo) | [x] | [ ] parcial |
| Mais álbuns do artista | [x] | [x] |
| Navegar (BrowseScreen) | [x] | [x] |
| Podcasts | [x] | [ ] |
| Notificações (lançamentos de artistas seguidos) | [x] | [ ] |
| Estatísticas (períodos, relógio, impressão digital, décadas) | [x] | [ ] parcial |
| Wrapped (10 cartões, compartilhar) | [x] | [ ] parcial |
| Ouvir Junto | [x] | [ ] |
| Login YouTube / Spotify (Last.fm e Discord: usuário não quer) | [x] | [ ] só YouTube |
| Créditos / Sobre / Bibliotecas | [x] | [x] |
| Log do app (opções de desenvolvedor) | [x] | [x] |

## Player
| Item | K | S |
|---|---|---|
| Estilo Classic | [x] | [x] |
| Estilo M3 Expressive | [x] | [x] |
| Estilo Apple Music | [x] | [x] |
| Estilo SoundCloud | [x] | [x] |
| Tela cheia / videoclipe com legendas | [x] | [ ] parcial |
| Canvas Spotify / capa animada Apple Music | [x] | [ ] |
| Comentários do vídeo | [x] | [ ] |
| Letras: fontes, palavra por palavra, tradução, romanização | [x] | [x] |
| Letras: estilo Apple Music (desfoque, brilho) | [x] | [ ] parcial |
| Letras: votar / enviar / tradução por IA | [x] | [ ] |
| Velocidade e tom | [x] | [x] |
| Temporizador de sono | [x] | [x] |

## Ajustes (SettingScreen.kt)
| Opção | K | S |
|---|---|---|
| Tema, cor do tema, cor personalizada | [x] | [ ] parcial |
| Vidro líquido | [x] | [ ] |
| Estilo do player / estilo da letra / romanização | [x] | [x] |
| Contas do YouTube (várias) | [x] | [ ] |
| Idioma do app | [x] | [ ] |
| País do conteúdo, idioma de áudio preferido | [x] | [x] |
| Qualidade (áudio, vídeo, download áudio/vídeo) | [x] | [ ] parcial |
| Baixar curtidas automaticamente | [x] | [x] |
| Downloads inteligentes + tamanho | [x] | [x] |
| Vídeo em vez de áudio | [x] | [x] |
| Rádio só áudio | [x] | [x] |
| Sincronizar seguidos com YouTube | [x] | [ ] |
| Enviar histórico ao Google | [x] | [ ] |
| Conteúdo explícito | [x] | [x] |
| Playlists do YouTube offline | [x] | [ ] |
| Juntar curtidas locais e do YouTube | [x] | [ ] |
| Proxy (tipo, host, porta, usuário, senha) | [x] | [ ] |
| Normalizar volume / pular silêncio | [x] | [x] |
| Equalizador do sistema | [—] iOS não oferece | [—] |
| Equalizador 10 bandas + AutoEq | [x] | [x] |
| Delay / Reverb | [x] | [x] |
| Áudio 8D | [x] | [x] |
| Salvar estado / aleatório e repetir | [x] | [x] |
| Encerrar serviço ao sair | [—] não existe no iOS | [—] |
| Crossfade, duração, DJ, pular em álbum, AutoMix | [x] | [ ] parcial |
| Histórico local + limpar histórico | [x] | [x] |
| Provedor principal de letra, atraso, idioma da tradução, idioma da legenda | [x] | [x] (legenda: falta) |
| Ajudar a base de letras (nome, e-mail) | [x] | [ ] |
| IA (provedor, chave, modelo, cabeçalhos, tradução por IA) | [x] | [ ] |
| Spotify (letras, Canvas) / capa animada | [x] | [ ] |
| Discord Rich Presence | [—] usuário não quer | [—] usuário não quer |
| Last.fm scrobble | [—] usuário não quer | [—] usuário não quer |
| SponsorBlock + categorias | [x] | [x] |
| Armazenamento / cache do player / limites | [x] (sem limite: AVPlayer não tem cache próprio) | [ ] |
| Backup de baixadas, backup automático, frequência, manter N | [x] | [x] |
| Backup/restauração compatível com Android/desktop | [x] | [ ] |
| Importar playlists de outros apps | [x] | [ ] |
| Sobre, versão, atualização, autor, blog, avisos do blog, doação, licenças | [x] parcial | [ ] |
| Log do app | [x] | [x] |
| Sincronizar login | [x] | [x] só YouTube |
| Sincronizar biblioteca (canal pareado) | [ ] | [ ] |
| Shazam | [—] usuário não quer | [—] usuário não quer |
| Android Auto / Google Cast | [—] AirPlay no lugar | [—] |
