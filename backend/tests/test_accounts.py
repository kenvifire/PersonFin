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
