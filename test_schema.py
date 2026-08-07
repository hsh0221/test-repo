from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel


class MeResponse(BaseModel):
    id: int
    github_login: str
    avatar_url: str | None
    role: str


class PullRequestSummary(BaseModel):
    id: int
    repository_full_name: str
    pr_number: int
    title: str | None
    head_sha: str
    state: str
    gate_state: str
    html_url: str
    quiz_id: int | None = None


class QuestionForAttempt(BaseModel):
    """응시 화면용 문항. correct_answer와 explanation은 의도적으로 없다 (§8.1)."""

    id: int
    seq: int
    body: str
    choices: list[str]


class AttemptStartResponse(BaseModel):
    attempt_id: int
    started_at: datetime
    time_limit_seconds: int
    questions: list[QuestionForAttempt]


class SubmittedAnswer(BaseModel):
    question_id: int
    answer: int


class SubmitRequest(BaseModel):
    answers: list[SubmittedAnswer]


class GradedQuestion(BaseModel):
    """채점 완료 후에만 쓰인다. 여기서 처음으로 정답과 해설이 나간다 (§8.1-2)."""

    id: int
    seq: int
    body: str
    choices: list[str]
    submitted_answer: int | None
    correct_answer: int | None
    is_correct: bool
    explanation: str | None


class AttemptResultResponse(BaseModel):
    attempt_id: int
    score: Decimal
    passed: bool
    correct_count: int
    graded_count: int
    questions: list[GradedQuestion]

