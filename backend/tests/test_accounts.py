def test_account_crud_scoped_to_user(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")

    created = client.post(
        "/accounts",
        json={"name": "RBC RRSP", "institution": "RBC", "account_type": "rrsp"},
        headers=headers_a,
    ).json()
    account_id = created["id"]

    assert client.get(f"/accounts/{account_id}", headers=headers_a).status_code == 200
    assert client.get(f"/accounts/{account_id}", headers=headers_b).status_code == 404
    assert len(client.get("/accounts", headers=headers_a).json()) == 1
    assert client.delete(f"/accounts/{account_id}", headers=headers_a).status_code == 204
    assert client.get(f"/accounts/{account_id}", headers=headers_a).status_code == 404


def test_create_account_returns_created_fields(client, auth_header_for):
    headers = auth_header_for("create@example.com")

    response = client.post(
        "/accounts",
        json={"name": "TD Chequing", "institution": "TD", "account_type": "cash"},
        headers=headers,
    )

    assert response.status_code == 201
    body = response.json()
    assert body["name"] == "TD Chequing"
    assert body["institution"] == "TD"
    assert body["account_type"] == "cash"
    assert "id" in body
    assert "created_at" in body


def test_list_accounts_only_returns_own_accounts(client, auth_header_for):
    headers_a = auth_header_for("lista@example.com")
    headers_b = auth_header_for("listb@example.com")

    client.post(
        "/accounts",
        json={"name": "A1", "institution": "RBC", "account_type": "rrsp"},
        headers=headers_a,
    )
    client.post(
        "/accounts",
        json={"name": "B1", "institution": "TD", "account_type": "cash"},
        headers=headers_b,
    )

    response = client.get("/accounts", headers=headers_a)
    assert response.status_code == 200
    names = [account["name"] for account in response.json()]
    assert names == ["A1"]


def test_patch_account_updates_fields(client, auth_header_for):
    headers = auth_header_for("patch@example.com")
    created = client.post(
        "/accounts",
        json={"name": "Old Name", "institution": "RBC", "account_type": "rrsp"},
        headers=headers,
    ).json()

    response = client.patch(
        f"/accounts/{created['id']}",
        json={"name": "New Name", "institution": "RBC", "account_type": "rrsp"},
        headers=headers,
    )

    assert response.status_code == 200
    assert response.json()["name"] == "New Name"


def test_patch_another_users_account_returns_404(client, auth_header_for):
    headers_a = auth_header_for("patcha@example.com")
    headers_b = auth_header_for("patchb@example.com")
    created = client.post(
        "/accounts",
        json={"name": "A Account", "institution": "RBC", "account_type": "rrsp"},
        headers=headers_a,
    ).json()

    response = client.patch(
        f"/accounts/{created['id']}",
        json={"name": "Hijacked", "institution": "RBC", "account_type": "rrsp"},
        headers=headers_b,
    )

    assert response.status_code == 404


def test_delete_another_users_account_returns_404(client, auth_header_for):
    headers_a = auth_header_for("deletea@example.com")
    headers_b = auth_header_for("deleteb@example.com")
    created = client.post(
        "/accounts",
        json={"name": "A Account", "institution": "RBC", "account_type": "rrsp"},
        headers=headers_a,
    ).json()

    response = client.delete(f"/accounts/{created['id']}", headers=headers_b)

    assert response.status_code == 404
    # The account still exists for its owner.
    assert client.get(f"/accounts/{created['id']}", headers=headers_a).status_code == 200


def test_accounts_require_authentication(client):
    assert client.get("/accounts").status_code == 401
    assert client.post("/accounts", json={"name": "X", "institution": "Y", "account_type": "cash"}).status_code == 401


_SNAPSHOT = {"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 100.0, "currency": "USD", "country": "CA"}]}


def test_delete_account_with_snapshots_is_409_and_keeps_history(client, auth_header_for, db_session):
    from app.models import Holding, Snapshot

    headers = auth_header_for("history@example.com")
    account_id = client.post("/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers).json()["id"]
    assert client.post(f"/accounts/{account_id}/snapshots", json=_SNAPSHOT, headers=headers).status_code == 201

    response = client.delete(f"/accounts/{account_id}", headers=headers)

    assert response.status_code == 409
    assert client.get(f"/accounts/{account_id}", headers=headers).status_code == 200
    db_session.expire_all()
    assert db_session.query(Snapshot).filter(Snapshot.account_id == account_id).count() == 1
    assert db_session.query(Holding).count() == 1
    assert client.get("/dashboard?currency=USD", headers=headers).json()["net_worth"] == 100.0


def test_delete_account_without_snapshots_is_204(client, auth_header_for):
    headers = auth_header_for("mistake@example.com")
    account_id = client.post("/accounts", json={"name": "Oops", "institution": "RBC", "account_type": "cash"}, headers=headers).json()["id"]

    assert client.delete(f"/accounts/{account_id}", headers=headers).status_code == 204
    assert client.get(f"/accounts/{account_id}", headers=headers).status_code == 404


def test_patch_account_is_a_partial_update(client, auth_header_for):
    headers = auth_header_for("partial@example.com")
    created = client.post("/accounts", json={"name": "Old Name", "institution": "RBC", "account_type": "rrsp"}, headers=headers).json()

    response = client.patch(f"/accounts/{created['id']}", json={"name": "New Name"}, headers=headers)

    assert response.status_code == 200
    body = response.json()
    assert body["name"] == "New Name"
    assert body["institution"] == "RBC"
    assert body["account_type"] == "rrsp"

    # An empty patch changes nothing; an explicit null is rejected.
    assert client.patch(f"/accounts/{created['id']}", json={}, headers=headers).json()["name"] == "New Name"
    assert client.patch(f"/accounts/{created['id']}", json={"institution": None}, headers=headers).status_code == 422
    assert client.get(f"/accounts/{created['id']}", headers=headers).json()["institution"] == "RBC"
