from __future__ import annotations

import asyncio
import hashlib
import hmac
import time
from pathlib import Path
from urllib.parse import quote

import boto3
from botocore.config import Config

from app.config import Settings


class StorageError(RuntimeError):
    pass


class StorageGateway:
    def object_uri(self, key: str) -> str:
        raise NotImplementedError

    def object_key(self, uri: str) -> str:
        raise NotImplementedError

    async def create_upload_url(self, key: str, content_type: str) -> str:
        raise NotImplementedError

    async def read(self, uri: str) -> bytes:
        raise NotImplementedError

    async def delete(self, uri: str) -> None:
        raise NotImplementedError


class LocalStorage(StorageGateway):
    def __init__(self, settings: Settings) -> None:
        self.root = settings.local_storage_path.resolve()
        self.public_base_url = settings.public_base_url.rstrip("/")
        self.secret = settings.jwt_secret.encode()
        self.ttl = settings.upload_url_ttl_seconds
        self.root.mkdir(parents=True, exist_ok=True)

    def object_uri(self, key: str) -> str:
        return f"local://{key.lstrip('/')}"

    def object_key(self, uri: str) -> str:
        return uri.removeprefix("local://").lstrip("/")

    def _path(self, uri_or_key: str) -> Path:
        key = uri_or_key.removeprefix("local://").lstrip("/")
        path = (self.root / key).resolve()
        if not path.is_relative_to(self.root):
            raise StorageError("허용되지 않은 스토리지 경로입니다")
        return path

    def _signature(self, key: str, expires: int) -> str:
        message = f"{key}:{expires}".encode()
        return hmac.new(self.secret, message, hashlib.sha256).hexdigest()

    async def create_upload_url(self, key: str, content_type: str) -> str:
        del content_type
        expires = int(time.time()) + self.ttl
        signature = self._signature(key, expires)
        return (
            f"{self.public_base_url}/v1/uploads/{quote(key, safe='/')}"
            f"?expires={expires}&signature={signature}"
        )

    def verify_upload(self, key: str, expires: int, signature: str) -> bool:
        if expires < int(time.time()):
            return False
        return hmac.compare_digest(signature, self._signature(key, expires))

    async def write(self, key: str, body: bytes) -> None:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        await asyncio.to_thread(path.write_bytes, body)

    async def read(self, uri: str) -> bytes:
        path = self._path(uri)
        if not path.exists():
            raise StorageError(f"오디오 파일을 찾을 수 없습니다: {uri}")
        return await asyncio.to_thread(path.read_bytes)

    async def delete(self, uri: str) -> None:
        path = self._path(uri)
        if path.exists():
            await asyncio.to_thread(path.unlink)


class S3Storage(StorageGateway):
    def __init__(self, settings: Settings) -> None:
        self.bucket = settings.s3_bucket
        self.ttl = settings.upload_url_ttl_seconds
        if not self.bucket:
            raise StorageError("STORAGE_BACKEND=s3일 때 S3_BUCKET이 필요합니다")
        boto_config = Config(
            s3={"addressing_style": "path" if settings.s3_force_path_style else "auto"}
        )
        self.client = boto3.client(
            "s3",
            endpoint_url=settings.s3_endpoint_url,
            region_name=settings.s3_region,
            aws_access_key_id=settings.s3_access_key_id,
            aws_secret_access_key=settings.s3_secret_access_key,
            config=boto_config,
        )
        self.presign_client = boto3.client(
            "s3",
            endpoint_url=settings.s3_public_endpoint_url or settings.s3_endpoint_url,
            region_name=settings.s3_region,
            aws_access_key_id=settings.s3_access_key_id,
            aws_secret_access_key=settings.s3_secret_access_key,
            config=boto_config,
        )

    def object_uri(self, key: str) -> str:
        return f"s3://{self.bucket}/{key.lstrip('/')}"

    def object_key(self, uri: str) -> str:
        return self._key(uri)

    def _key(self, uri: str) -> str:
        prefix = f"s3://{self.bucket}/"
        if not uri.startswith(prefix):
            raise StorageError("다른 버킷의 객체에는 접근할 수 없습니다")
        return uri.removeprefix(prefix)

    async def create_upload_url(self, key: str, content_type: str) -> str:
        return await asyncio.to_thread(
            self.presign_client.generate_presigned_url,
            "put_object",
            Params={"Bucket": self.bucket, "Key": key, "ContentType": content_type},
            ExpiresIn=self.ttl,
        )

    async def read(self, uri: str) -> bytes:
        def download() -> bytes:
            response = self.client.get_object(Bucket=self.bucket, Key=self._key(uri))
            return response["Body"].read()

        return await asyncio.to_thread(download)

    async def delete(self, uri: str) -> None:
        await asyncio.to_thread(
            self.client.delete_object,
            Bucket=self.bucket,
            Key=self._key(uri),
        )


def create_storage(settings: Settings) -> StorageGateway:
    if settings.storage_backend == "s3":
        return S3Storage(settings)
    return LocalStorage(settings)
