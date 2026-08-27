# Claude Code サンドボックス テンプレート

Claude Code を Dev Container の中で動かすためのオレオレテンプレート。
自律実行による意図しない外部通信や情報送信を防ぐため、コンテナの外向き通信はデフォルト遮断し、許可リストのドメインだけを通す。
ホストPCが属しているプライベートネットワーク（192.168）はデフォルトで許可している。

## セットアップ

1. このテンプレートから新規リポジトリを作成する
2. VS Code で開き、「Dev Containers: Reopen in Container」を実行する
3. コンテナ起動時にファイアウォールが自動構築される（`postStartCommand`）

前提: Docker / VS Code + Dev Containers 拡張。

## 設定

| ファイル                            | 役割                                            |
| ----------------------------------- | ----------------------------------------------- |
| `.devcontainer/allowed-domains.txt` | 通信を許可するドメイン（1行1つ、`#`はコメント） |
| `.claude/settings.json`             | Claude Code の allow / deny ルールとフック登録  |
| `.claude/CLAUDE.md`                 | 応答言語や作業ルールなどのプロジェクト指示      |

### 通信先を追加する

`.devcontainer/allowed-domains.txt` に追記する。
起動中の追加は cron により最大5分で反映される。すぐ反映したいなら `sudo /usr/local/bin/init-firewall.sh` を再実行。

デフォルトで許可しているもの:

- npm レジストリ
- api.anthropic.com
- GitHub の全 IP レンジ
- VS Code Marketplace 系
- qiita.com / zenn.dev / stackoverflow.com

## 注意

- ファイアウォールは事故防止のための緩和策で、完全な隔離ではない。
- コンテナは `NET_ADMIN` / `NET_RAW` 付きで起動し、`node` ユーザーに `init-firewall.sh` 限定の sudo を与えている。

## ライセンス

[The Unlicense](LICENSE)
