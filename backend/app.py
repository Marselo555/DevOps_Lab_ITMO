import os
from contextlib import closing

import psycopg2
from flask import Flask, jsonify, request, send_from_directory


app = Flask(__name__, static_folder="../frontend", static_url_path="/static")


@app.after_request
def identify_instance(response):
    instance_id = os.environ.get("INSTANCE_ID")
    if instance_id:
        response.headers["X-Instance-ID"] = instance_id
    return response


def db_connection():
    return psycopg2.connect(
        host=os.environ.get("DB_HOST", "127.0.0.1"),
        port=os.environ.get("DB_PORT", "55432"),
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    )


def note_dict(row):
    return {"id": row[0], "title": row[1], "content": row[2]}


def note_input():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return None
    title = data.get("title")
    content = data.get("content")
    if not isinstance(title, str) or not title.strip() or not isinstance(content, str):
        return None
    return title.strip(), content


@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/api/notes")
def list_notes():
    with closing(db_connection()) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT id, title, content FROM notes ORDER BY id DESC")
            notes = [note_dict(row) for row in cursor.fetchall()]
    return jsonify(notes)


@app.post("/api/notes")
def create_note():
    values = note_input()
    if values is None:
        return jsonify(error="Укажите заголовок и текст заметки."), 400
    with closing(db_connection()) as connection:
        with connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "INSERT INTO notes (title, content) VALUES (%s, %s) "
                    "RETURNING id, title, content",
                    values,
                )
                note = note_dict(cursor.fetchone())
    return jsonify(note), 201


@app.put("/api/notes/<int:note_id>")
def update_note(note_id):
    values = note_input()
    if values is None:
        return jsonify(error="Укажите заголовок и текст заметки."), 400
    with closing(db_connection()) as connection:
        with connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "UPDATE notes SET title = %s, content = %s WHERE id = %s "
                    "RETURNING id, title, content",
                    (*values, note_id),
                )
                row = cursor.fetchone()
    if row is None:
        return jsonify(error="Заметка не найдена."), 404
    return jsonify(note_dict(row))


@app.delete("/api/notes/<int:note_id>")
def delete_note(note_id):
    with closing(db_connection()) as connection:
        with connection:
            with connection.cursor() as cursor:
                cursor.execute("DELETE FROM notes WHERE id = %s RETURNING id", (note_id,))
                row = cursor.fetchone()
    if row is None:
        return jsonify(error="Заметка не найдена."), 404
    return "", 204


def init_db():
    with closing(db_connection()) as connection:
        with connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "CREATE TABLE IF NOT EXISTS notes ("
                    "id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
                    "title TEXT NOT NULL, "
                    "content TEXT NOT NULL)"
                )


if __name__ == "__main__":
    init_db()
    app.run(
        host=os.environ.get("APP_HOST", "127.0.0.1"),
        port=int(os.environ.get("APP_PORT", "8000")),
    )
