export interface RatingInfo {
  score: number;
  count: number;
}

export interface DatasetItem {
  id: number;
  name: string;
  category: string;
  price: number;
  quantity: number;
  active: boolean;
  tags: string[];
  rating: RatingInfo;
}

export interface ProcessedItem extends DatasetItem {
  total: number;
}

export interface DbItem {
  id: number;
  name: string;
  category: string;
  price: number;
  quantity: number;
  active: boolean;
  tags: string[];
  rating: RatingInfo;
}

export interface CrudCreateRequest {
  id: number;
  name: string;
  category: string;
  price: number;
  quantity: number;
  active?: boolean;
  tags?: string[];
}

export interface CrudUpdateRequest {
  name?: string;
  price?: number;
  quantity?: number;
}

/** Serialized as `{ "items": [...], "count": N }`. */
export class ListWithCount<T> {
  readonly count: number;
  constructor(readonly items: T[]) {
    this.count = items.length;
  }
}
