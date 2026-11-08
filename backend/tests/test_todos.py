def test_create_list_complete_todo_scoped_to_user(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")

    created = client.post("/todos", json={"description": "Trim crypto to 10%", "related_asset_class": "crypto"}, headers=headers_a).json()
    todo_id = created["id"]

    assert client.get(f"/todos", headers=headers_a).json()[0]["done"] is False
    assert client.patch(f"/todos/{todo_id}", json={"done": True}, headers=headers_b).status_code == 404
    patched = client.patch(f"/todos/{todo_id}", json={"done": True}, headers=headers_a).json()
    assert patched["done"] is True


def test_list_todos_filters_by_done_false(client, auth_header_for):
    headers = auth_header_for("filter@example.com")
    open_todo = client.post("/todos", json={"description": "Open"}, headers=headers).json()
    done_todo = client.post("/todos", json={"description": "Done"}, headers=headers).json()
    client.patch(f"/todos/{done_todo['id']}", json={"done": True}, headers=headers)

    all_todos = client.get("/todos", headers=headers).json()
    open_todos = client.get("/todos?done=false", headers=headers).json()

    assert len(all_todos) == 2
    assert [todo["id"] for todo in open_todos] == [open_todo["id"]]


def test_delete_todo_scoped_to_user(client, auth_header_for):
    headers_a = auth_header_for("dela@example.com")
    headers_b = auth_header_for("delb@example.com")
    todo_id = client.post("/todos", json={"description": "Rebalance"}, headers=headers_a).json()["id"]

    assert client.delete(f"/todos/{todo_id}", headers=headers_b).status_code == 404
    assert client.delete(f"/todos/{todo_id}", headers=headers_a).status_code == 204
    assert client.get("/todos", headers=headers_a).json() == []
