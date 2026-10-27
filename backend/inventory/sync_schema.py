"""Strict, bounded wire inputs; unknown/deletion fields are rejected."""
from datetime import datetime
from decimal import Decimal
from typing import Annotated, Literal
from pydantic import BaseModel, ConfigDict, Field, field_validator
from django.utils import timezone

Key = Annotated[str, Field(min_length=1, max_length=200)]
Code = Annotated[str, Field(min_length=1, max_length=100)]
Name = Annotated[str, Field(min_length=1, max_length=200)]
Price = Annotated[Decimal, Field(ge=0, max_digits=10, decimal_places=2)]
Digest = Annotated[str, Field(pattern=r'^[0-9a-f]{64}$')]


class Strict(BaseModel):
    model_config = ConfigDict(extra='forbid')


class ProductData(Strict):
    code: Code
    name: Name
    default_purchase_price: Price | None = None
    default_sale_price: Price | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None


class Line(Strict):
    id: Key
    product_code: Code
    product_name: Name
    quantity: Annotated[int, Field(strict=True, gt=0, le=100000000)]


class InboundLine(Line):
    purchase_price: Price | None = None
    sale_price: Price | None = None


class Document(Strict):
    created_at: datetime

    @field_validator('created_at')
    @classmethod
    def aware_date(cls, value):
        return timezone.make_aware(value) if timezone.is_naive(value) else value


class InboundData(Document):
    tracking_number: Code
    seller_order_number: Annotated[str, Field(max_length=100)] | None = None
    rebate_order_number: Annotated[str, Field(max_length=100)] | None = None
    scheme_number: Annotated[str, Field(max_length=100)] | None = None
    ocr_status: Literal['pending', 'processing', 'needsReview', 'confirmed', 'failed'] = 'confirmed'
    is_settled: bool = False
    image_sha256: Digest | None = None
    items: Annotated[list[InboundLine], Field(max_length=1000)]


class OutboundData(Document):
    logistics_number: Annotated[str, Field(max_length=100)] | None = None
    note: Annotated[str, Field(max_length=10000)] | None = None
    image_sha256s: Annotated[list[Digest], Field(max_length=30)] = []
    items: Annotated[list[Line], Field(min_length=1, max_length=1000)]


class Operation(Strict):
    operation_id: Key
    kind: Literal['product', 'inbound', 'outbound']
    id: Key
    base_revision: Annotated[int, Field(strict=True, ge=0)]
    data: dict


class Push(Strict):
    device_id: Key
    operations: Annotated[list[dict], Field(min_length=1, max_length=50)]
