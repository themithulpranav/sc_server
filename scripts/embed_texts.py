#!/usr/bin/env python3
"""
Read JSON from stdin, emit embedding JSON on stdout.

Input:
  {
    "source_texts": ["...", ...],
    "pdf_extracted_texts": ["...", ...],
    "url_extracted_texts": ["...", ...]
  }

Output:
  {
    "model": "all-MiniLM-L6-v2",
    "dim": <int>,
    "source_embeddings": [[float], ...],
    "pdf_extracted_embeddings": [[float], ...],
    "url_extracted_embeddings": [[float], ...]
  }

Long texts: token windows with overlap, mean-pool chunk vectors, L2-normalize.
"""

from __future__ import annotations

import json
import sys

import numpy as np

MODEL_NAME = "all-MiniLM-L6-v2"
CHUNK_OVERLAP_TOKENS = 32


def l2_normalize(vec: np.ndarray) -> np.ndarray:
    n = float(np.linalg.norm(vec))
    if n == 0.0:
        return vec
    return vec / n


def token_chunk_spans(token_ids: list[int], max_len: int, overlap: int) -> list[tuple[int, int]]:
    if len(token_ids) <= max_len:
        return [(0, len(token_ids))]

    stride = max(1, max_len - overlap)
    spans = []
    start = 0
    while start < len(token_ids):
        end = min(start + max_len, len(token_ids))
        spans.append((start, end))
        if end >= len(token_ids):
            break
        start += stride
    return spans


def embed_single_text(model, tokenizer, text: str, max_len: int) -> np.ndarray:
    if text is None:
        text = ""
    text = str(text)

    token_ids = tokenizer.encode(text, add_special_tokens=False)
    if not token_ids:
        return model.encode([text], normalize_embeddings=True)[0]

    if len(token_ids) <= max_len:
        return model.encode([text], normalize_embeddings=True)[0]

    chunk_texts = []
    for start, end in token_chunk_spans(token_ids, max_len, CHUNK_OVERLAP_TOKENS):
        chunk_ids = token_ids[start:end]
        chunk_text = tokenizer.decode(chunk_ids, skip_special_tokens=True).strip()
        if chunk_text:
            chunk_texts.append(chunk_text)

    if not chunk_texts:
        frag = tokenizer.decode(token_ids[:max_len], skip_special_tokens=True)
        return model.encode([frag], normalize_embeddings=True)[0]

    chunk_embs = model.encode(chunk_texts, normalize_embeddings=True)
    pooled = np.mean(np.asarray(chunk_embs), axis=0)
    return l2_normalize(pooled)


def embed_bucket(model, tokenizer, texts: list[str], max_len: int) -> list[list[float]]:
    return [embed_single_text(model, tokenizer, t, max_len).tolist() for t in texts]


def main() -> None:
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"Invalid JSON on stdin: {exc}", file=sys.stderr)
        sys.exit(1)

    source_texts = [str(x) for x in (data.get("source_texts") or [])]
    pdf_texts = [str(x) for x in (data.get("pdf_extracted_texts") or [])]
    url_texts = [str(x) for x in (data.get("url_extracted_texts") or [])]

    from sentence_transformers import SentenceTransformer

    model = SentenceTransformer(MODEL_NAME)
    tokenizer = model.tokenizer
    max_len = int(model.max_seq_length)

    source_embeddings = embed_bucket(model, tokenizer, source_texts, max_len)
    pdf_embeddings = embed_bucket(model, tokenizer, pdf_texts, max_len)
    url_embeddings = embed_bucket(model, tokenizer, url_texts, max_len)

    dim = model.get_sentence_embedding_dimension()

    out = {
        "model": MODEL_NAME,
        "dim": dim,
        "source_embeddings": source_embeddings,
        "pdf_extracted_embeddings": pdf_embeddings,
        "url_extracted_embeddings": url_embeddings,
    }
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
