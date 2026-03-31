from contextlib import asynccontextmanager

from fastapi import FastAPI
import structlog

logger = structlog.get_logger()


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("gang-of-none starting")
    yield
    logger.info("gang-of-none shutting down")


app = FastAPI(title="gang-of-none", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok"}
