import unittest

from backend.app import app, init_db


class NotesApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        init_db()

    def test_create_read_update_delete(self):
        client = app.test_client()
        response = client.post(
            "/api/notes", json={"title": "CI note", "content": "before"}
        )
        self.assertEqual(response.status_code, 201)
        note_id = response.get_json()["id"]
        self.addCleanup(lambda: client.delete(f"/api/notes/{note_id}"))

        response = client.get("/api/notes")
        self.assertEqual(response.status_code, 200)
        self.assertIn(note_id, [note["id"] for note in response.get_json()])

        response = client.put(
            f"/api/notes/{note_id}",
            json={"title": "CI note", "content": "after"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["content"], "after")

        response = client.delete(f"/api/notes/{note_id}")
        self.assertEqual(response.status_code, 204)
        response = client.get("/api/notes")
        self.assertNotIn(note_id, [note["id"] for note in response.get_json()])
