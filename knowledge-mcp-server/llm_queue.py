"""File-based LLM task queue for agent-shell backend.

When KNOWLEDGE_LLM_BACKEND=agent, LLM calls are queued as JSON files
in .agent-shell/llm-tasks/ for processing by an external agent (Claude
via agent-shell) instead of OpenAI.
"""

import json
import os
import uuid
from datetime import datetime, timezone


def queue_llm_task(project_root: str, task_type: str, prompt: str, context: dict = None) -> str:
    """Queue an LLM task to a file. Returns task UUID."""
    task_id = str(uuid.uuid4())[:8]
    tasks_dir = os.path.join(project_root, ".agent-shell", "llm-tasks")
    os.makedirs(tasks_dir, exist_ok=True)
    task = {
        "id": task_id,
        "type": task_type,  # "synthesis" | "entity_extraction" | "supersession_classification"
        "prompt": prompt,
        "context": context or {},
        "status": "pending",
        "result": None,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    filepath = os.path.join(tasks_dir, f"{task_id}.json")
    with open(filepath, "w") as f:
        json.dump(task, f, indent=2)
    return task_id


def get_llm_task(project_root: str, task_id: str) -> dict | None:
    """Read a task file by UUID."""
    filepath = os.path.join(project_root, ".agent-shell", "llm-tasks", f"{task_id}.json")
    if not os.path.exists(filepath):
        return None
    with open(filepath) as f:
        return json.load(f)


def submit_llm_result(project_root: str, task_id: str, result: str) -> bool:
    """Write result to task file and mark completed."""
    filepath = os.path.join(project_root, ".agent-shell", "llm-tasks", f"{task_id}.json")
    if not os.path.exists(filepath):
        return False
    with open(filepath) as f:
        task = json.load(f)
    task["status"] = "completed"
    task["result"] = result
    task["completed_at"] = datetime.now(timezone.utc).isoformat()
    with open(filepath, "w") as f:
        json.dump(task, f, indent=2)
    return True


def cleanup_task(project_root: str, task_id: str):
    """Delete task file after result is consumed."""
    filepath = os.path.join(project_root, ".agent-shell", "llm-tasks", f"{task_id}.json")
    if os.path.exists(filepath):
        os.remove(filepath)
