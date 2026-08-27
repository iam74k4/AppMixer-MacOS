#!/usr/bin/env python3
"""App Store Connect API を CI から叩くための小さな道具。

main へマージしたあとの「アップロード → 処理待ち → 審査提出 → 配信確認」を
人手を挟まずに進めるために使う。fastlane を丸ごと持ち込むほどの量ではないので、
必要な 3 つの操作だけを置く。

    wait-build   アップロードしたビルドの処理が終わるのを待つ
    submit       バージョンにビルドを紐づけ、リリースノートを入れて審査に出す
    state        いま App Store 側がそのバージョンをどう扱っているかを表示する

認証は App Store Connect API キー（.p8）。次の環境変数を読む。

    ASC_API_KEY_ID      キー ID
    ASC_API_ISSUER_ID   Issuer ID
    ASC_API_KEY_P8      .p8 の中身そのもの
    ASC_BUNDLE_ID       対象アプリのバンドル ID

依存は PyJWT（と cryptography）だけ。HTTP は標準ライブラリで足りる。
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

BASE = "https://api.appstoreconnect.apple.com"
PLATFORM = "MAC_OS"

# 配信が始まった状態。ここに来たらタグを打ってよい。
# appVersionState では READY_FOR_DISTRIBUTION、旧 appStoreState では READY_FOR_SALE。
LIVE_STATES = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION"}
# 人が App Store Connect で操作しないと先に進まない状態。待っても変わらない。
STUCK_STATES = {
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
    "DEVELOPER_REMOVED_FROM_SALE",
}


def log(message):
    # 進捗は stderr へ出す。stdout は呼び出し側が値として読むため混ぜない。
    print(message, file=sys.stderr, flush=True)


def die(message):
    log(f"error: {message}")
    sys.exit(1)


# --- API ------------------------------------------------------------------


def token():
    """20 分で切れる ES256 の JWT を作る。Apple は 20 分より長いものを拒む。"""
    key_id = os.environ.get("ASC_API_KEY_ID")
    issuer = os.environ.get("ASC_API_ISSUER_ID")
    private_key = os.environ.get("ASC_API_KEY_P8")
    if not (key_id and issuer and private_key):
        die("ASC_API_KEY_ID / ASC_API_ISSUER_ID / ASC_API_KEY_P8 が要ります。")
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def api(method, path, body=None, params=None):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token()}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        # Apple のエラーは本文にしか理由が書かれていない。捨てると原因が追えない。
        detail = error.read().decode(errors="replace")
        raise ApiError(error.code, detail) from None


class ApiError(Exception):
    def __init__(self, status, detail):
        super().__init__(f"HTTP {status}: {detail}")
        self.status = status
        self.detail = detail


def app_id():
    bundle_id = os.environ.get("ASC_BUNDLE_ID")
    if not bundle_id:
        die("ASC_BUNDLE_ID が要ります。")
    found = api("GET", "/v1/apps", params={"filter[bundleId]": bundle_id})["data"]
    if not found:
        die(
            f"バンドル ID {bundle_id} のアプリが見つかりません。"
            " App Store Connect にアプリレコードを作ってください。"
        )
    return found[0]["id"]


# --- wait-build -----------------------------------------------------------


def find_build(app, build_number, version):
    """アップロードしたビルドを探す。

    ASC では builds.version が CFBundleVersion（ビルド番号）で、
    preReleaseVersion.version が表示用バージョン。名前が紛らわしいので注意。

    まず両方で絞る。空振りしたときはビルド番号だけでもう一度見る。表示用
    バージョンでの絞り込みが効かない場合に、一致するビルドが目の前にあるのに
    タイムアウトまで待ち続けるのを避けるため。
    """
    for extra in ({"filter[preReleaseVersion.version]": version}, {}):
        found = api(
            "GET",
            "/v1/builds",
            params={
                "filter[app]": app,
                "filter[version]": build_number,
                "limit": 1,
                **extra,
            },
        )["data"]
        if found:
            return found[0]
    return None


def cmd_wait_build(args):
    app = app_id()
    deadline = time.time() + args.timeout
    while True:
        build = find_build(app, args.build, args.version)
        if build is None:
            log(f"ビルド {args.version} ({args.build}) はまだ現れていません。")
        else:
            state = build["attributes"].get("processingState")
            log(f"processingState: {state}")
            if state == "VALID":
                print(build["id"])
                return
            if state in ("INVALID", "FAILED"):
                die(
                    f"ビルドの処理が {state} で終わりました。"
                    " App Store Connect か、Apple からのメールに理由が出ています。"
                )
        if time.time() >= deadline:
            die(
                f"{args.timeout} 秒待ちましたが処理が終わりませんでした。"
                "アップロード自体は終わっているので、App Store Connect で"
                "処理の終了を確認してから、release ワークフローを"
                "workflow_dispatch で再実行してください。"
            )
        time.sleep(args.interval)


# --- submit ---------------------------------------------------------------


def version_state(version):
    """appStoreState は 3.3 で非推奨。新しい appVersionState を先に見る。"""
    attributes = version["attributes"]
    return attributes.get("appVersionState") or attributes.get("appStoreState")


def find_version(app, version_string):
    found = api(
        "GET",
        f"/v1/apps/{app}/appStoreVersions",
        params={
            "filter[versionString]": version_string,
            "filter[platform]": PLATFORM,
            "limit": 1,
        },
    )["data"]
    return found[0] if found else None


def find_or_create_version(app, version_string, release_type):
    version = find_version(app, version_string)
    if version is not None:
        state = version_state(version)
        if state in LIVE_STATES:
            die(
                f"{version_string} は既に配信済み（{state}）です。"
                " bundle/Info.plist のバージョンを上げてください。"
            )
        log(f"既存のバージョン {version_string} を使います（{state}）。")
        return version["id"]

    log(f"バージョン {version_string} を作ります（releaseType={release_type}）。")
    created = api(
        "POST",
        "/v1/appStoreVersions",
        body={
            "data": {
                "type": "appStoreVersions",
                "attributes": {
                    "platform": PLATFORM,
                    "versionString": version_string,
                    "releaseType": release_type,
                },
                "relationships": {"app": {"data": {"type": "apps", "id": app}}},
            }
        },
    )
    return created["data"]["id"]


def set_whats_new(version_id, notes):
    """「このバージョンでの変更点」を全ロケールに入れる。

    アプリの最初のバージョンには変更点の欄が無く、Apple は 409 を返す。
    それは失敗ではないので警告にとどめる。
    """
    localizations = api(
        "GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
    )["data"]
    for localization in localizations:
        locale = localization["attributes"].get("locale")
        try:
            api(
                "PATCH",
                f"/v1/appStoreVersionLocalizations/{localization['id']}",
                body={
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": localization["id"],
                        "attributes": {"whatsNew": notes},
                    }
                },
            )
            log(f"リリースノートを入れました（{locale}）。")
        except ApiError as error:
            log(f"warning: {locale} のリリースノートを入れられませんでした: {error}")


def attach_build(version_id, build_id):
    api(
        "PATCH",
        f"/v1/appStoreVersions/{version_id}",
        body={
            "data": {
                "type": "appStoreVersions",
                "id": version_id,
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }
        },
    )
    log("ビルドをバージョンに紐づけました。")


def submit_for_review(app, version_id):
    """審査に出す。

    提出は 3 手に分かれている。提出物の入れ物（reviewSubmissions）を作り、
    そこにバージョンを入れ（reviewSubmissionItems）、最後に submitted=true にする。
    最後の一手を忘れると「作ったのに出ていない」状態になる。
    """
    existing = api(
        "GET",
        "/v1/reviewSubmissions",
        params={"filter[app]": app, "filter[state]": "READY_FOR_REVIEW", "limit": 1},
    )["data"]
    if existing:
        submission_id = existing[0]["id"]
        log("提出前の入れ物が残っていたので、それを使います。")
    else:
        submission_id = api(
            "POST",
            "/v1/reviewSubmissions",
            body={
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": PLATFORM},
                    "relationships": {"app": {"data": {"type": "apps", "id": app}}},
                }
            },
        )["data"]["id"]

    try:
        api(
            "POST",
            "/v1/reviewSubmissionItems",
            body={
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {
                            "data": {"type": "reviewSubmissions", "id": submission_id}
                        },
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        },
                    },
                }
            },
        )
    except ApiError as error:
        # 同じバージョンが既に入っている場合は、そのまま提出へ進めばよい。
        if error.status != 409:
            raise
        log("このバージョンは既に入れ物の中にありました。")

    api(
        "PATCH",
        f"/v1/reviewSubmissions/{submission_id}",
        body={
            "data": {
                "type": "reviewSubmissions",
                "id": submission_id,
                "attributes": {"submitted": True},
            }
        },
    )
    log("審査に提出しました。")


def cmd_submit(args):
    app = app_id()
    version_id = find_or_create_version(app, args.version, args.release_type)
    attach_build(version_id, args.build_id)

    if args.notes_file:
        notes = open(args.notes_file, encoding="utf-8").read().strip()
        if notes:
            set_whats_new(version_id, notes)
        else:
            log("warning: リリースノートが空でした。App Store Connect で入れてください。")

    if args.no_submit:
        log("--no-submit のため、審査には出しません。")
        return
    submit_for_review(app, version_id)


# --- state ----------------------------------------------------------------


def cmd_state(args):
    version = find_version(app_id(), args.version)
    if version is None:
        die(f"バージョン {args.version} は App Store Connect にありません。")
    state = version_state(version)
    print(state)
    if args.require_live and state not in LIVE_STATES:
        hint = (
            "人の操作を待っています。App Store Connect を見てください。"
            if state in STUCK_STATES
            else "まだ配信前です。"
        )
        log(f"{args.version} は {state}。{hint}")
        sys.exit(2)


# --- entry ----------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    wait = sub.add_parser("wait-build", help="ビルドの処理が終わるのを待つ")
    wait.add_argument("--version", required=True, help="表示用バージョン（0.1.0 など）")
    wait.add_argument("--build", required=True, help="ビルド番号（CFBundleVersion）")
    wait.add_argument("--timeout", type=int, default=3600)
    wait.add_argument("--interval", type=int, default=60)
    wait.set_defaults(func=cmd_wait_build)

    submit = sub.add_parser("submit", help="ビルドを紐づけて審査に出す")
    submit.add_argument("--version", required=True)
    submit.add_argument("--build-id", required=True)
    submit.add_argument("--notes-file")
    submit.add_argument("--release-type", default="AFTER_APPROVAL")
    submit.add_argument(
        "--no-submit",
        action="store_true",
        help="バージョンの用意までで止める（審査には出さない）",
    )
    submit.set_defaults(func=cmd_submit)

    state = sub.add_parser("state", help="バージョンの状態を表示する")
    state.add_argument("--version", required=True)
    state.add_argument(
        "--require-live",
        action="store_true",
        help="配信中でなければ終了コード 2 で終わる",
    )
    state.set_defaults(func=cmd_state)

    args = parser.parse_args()
    try:
        args.func(args)
    except ApiError as error:
        die(str(error))


if __name__ == "__main__":
    main()
