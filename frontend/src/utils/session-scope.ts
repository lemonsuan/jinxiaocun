export interface SessionScope { token: string; activeShopId: string; scopeVersion: number }
/** An epoch also rejects A → B → A responses whose visible IDs happen to match. */
export function sameScope(captured: SessionScope | undefined, current: SessionScope): boolean {
  return !!captured && captured.token === current.token && captured.activeShopId === current.activeShopId && captured.scopeVersion === current.scopeVersion
}
