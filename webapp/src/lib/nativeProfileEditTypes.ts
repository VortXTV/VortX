// Public sparse website profile event DTO. Shared contract: vortx-site/profileEditPatch.ts.
export interface ProfileSettings { avatar?: string; accent?: string; oled?: boolean; textScale?: number; isKids?: boolean; playback?: Record<string, any>; [key: string]: any }
export interface ProfileEdit { id: string; name?: string; familyEdit?: boolean; pin?: string | null; deleted?: boolean; settings?: ProfileSettings; disabledAddons?: string[]; [key: string]: any }
export function canonicalProfileID(value: unknown): string | null {
  if (typeof value !== "string" || !value.trim()) return null;
  const id = value.trim();
  return /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id) ? id.toUpperCase() : id;
}
