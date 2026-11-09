const form = document.querySelector("#note-form");
const titleInput = document.querySelector("#title");
const contentInput = document.querySelector("#content");
const notesList = document.querySelector("#notes");
const status = document.querySelector("#status");
const saveButton = document.querySelector("#save-button");
const cancelButton = document.querySelector("#cancel-button");
let editingId = null;

async function api(path, options) {
  const response = await fetch(path, options);
  if (!response.ok) {
    const body = await response.json();
    throw new Error(body.error || `Ошибка HTTP ${response.status}`);
  }
  return response.status === 204 ? null : response.json();
}

function stopEditing() {
  editingId = null;
  form.reset();
  saveButton.textContent = "Добавить заметку";
  cancelButton.hidden = true;
}

async function loadNotes() {
  const notes = await api("/api/notes");
  notesList.replaceChildren();

  for (const note of notes) {
    const item = document.createElement("li");
    const heading = document.createElement("h3");
    const content = document.createElement("p");
    const actions = document.createElement("div");
    const edit = document.createElement("button");
    const remove = document.createElement("button");

    heading.textContent = note.title;
    content.textContent = note.content;
    actions.className = "note-actions";
    edit.textContent = "Изменить";
    remove.textContent = "Удалить";

    edit.addEventListener("click", () => {
      editingId = note.id;
      titleInput.value = note.title;
      contentInput.value = note.content;
      saveButton.textContent = "Сохранить изменения";
      cancelButton.hidden = false;
      titleInput.focus();
    });

    remove.addEventListener("click", async () => {
      try {
        await api(`/api/notes/${note.id}`, { method: "DELETE" });
        if (editingId === note.id) stopEditing();
        await loadNotes();
        status.textContent = "Заметка удалена.";
      } catch (error) {
        status.textContent = error.message;
      }
    });

    actions.append(edit, remove);
    item.append(heading, content, actions);
    notesList.append(item);
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const path = editingId === null ? "/api/notes" : `/api/notes/${editingId}`;
  const method = editingId === null ? "POST" : "PUT";

  try {
    await api(path, {
      method,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: titleInput.value, content: contentInput.value }),
    });
    stopEditing();
    await loadNotes();
    status.textContent = "Заметка сохранена.";
  } catch (error) {
    status.textContent = error.message;
  }
});

cancelButton.addEventListener("click", stopEditing);
loadNotes().catch((error) => { status.textContent = error.message; });
