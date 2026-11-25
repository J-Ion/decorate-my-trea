-- =========================================================
-- 0006 — S21: 칠판 테마 제약 · 관리자 특별 트리 생성 RPC · 허락 대기 트리 숨김
--   spec.md 4.6 · 4.7 · 5.3, PR #13 리뷰 후속
-- 재실행해도 안전하게 작성 (if exists / create or replace).
-- =========================================================

-- ---------- 1) 일반 트리는 chalkboard 금지 (spec.md 4.7) ----------
-- 앱(saveTreeStyle)은 USER_THEME_IDS 로 막지만, 트리 주인이 REST 로 직접 update 하면
-- 그대로 저장되던 구멍을 DB 제약으로 막는다. 제약을 걸기 전에 이미 저장된 값은 지우지 않고
-- 기본 테마로 되돌린다 (일반 트리에 칠판 배경은 화면에서도 고를 수 없다).
update public.trees set theme = 'classic' where kind = 'user' and theme = 'chalkboard';

alter table public.trees drop constraint if exists trees_chalkboard_professor_only;
alter table public.trees add constraint trees_chalkboard_professor_only
  check (kind <> 'user' or theme <> 'chalkboard');

comment on constraint trees_chalkboard_professor_only on public.trees
  is '칠판 테마는 교수님·특별 트리 전용 (spec.md 4.7)';

-- ---------- 2) 관리자: 허락 대기 특별 트리 만들기 (spec.md 3장 · 4.6) ----------
-- 앱이 가진 trees INSERT 컬럼 권한에는 is_open 이 없어(0004) 트리가 열린 채 만들어지던 문제를 없앤다.
-- 만든 관리자(auth.uid())가 트리 주인이 되고, is_open = false(허락 대기)로 시작한다 — 관리자가 열어야 편지를 받는다.
-- 오류는 예외 문장 대신 코드로 돌려주고, 앱이 spec.md 2.3 의 사용자 문구로 바꾼다.
create or replace function public.admin_create_special_tree(
  p_title text,
  p_owner_name text,
  p_slug text default null,
  p_kind text default 'professor',
  p_theme text default 'chalkboard',
  p_department text default null,
  p_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_theme text := btrim(coalesce(p_theme, ''));
  v_title text := btrim(coalesce(p_title, ''));
  v_owner_name text := btrim(coalesce(p_owner_name, ''));
  v_slug text := nullif(btrim(lower(coalesce(p_slug, ''))), '');
  v_department text := nullif(btrim(coalesce(p_department, '')), '');
  v_description text := nullif(btrim(coalesce(p_description, '')), '');
  v_id uuid;
  v_created_slug text;
begin
  -- 관리자만. anon 에게는 실행 권한 자체를 주지 않지만, 함수를 직접 불러도 한 번 더 확인한다.
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_allowed');
  end if;

  if v_kind = '' then v_kind := 'professor'; end if;
  if v_kind not in ('professor', 'special') then
    return jsonb_build_object('ok', false, 'error', 'invalid_kind');
  end if;
  if v_theme = '' then v_theme := 'chalkboard'; end if;

  -- 입력 규칙은 0001 의 테이블 제약과 같다
  if v_title = '' or char_length(v_title) > 30 then
    return jsonb_build_object('ok', false, 'error', 'invalid_title');
  end if;
  if v_owner_name = '' or char_length(v_owner_name) > 20 then
    return jsonb_build_object('ok', false, 'error', 'invalid_owner_name');
  end if;
  -- 테마·학과는 앱이 아는 id 만 (lib/constants.ts 의 THEMES · DEPARTMENTS 와 같게 유지).
  -- 앱(readSpecialTreeForm)도 거르지만, 관리자가 RPC 를 직접 불러도 모르는 id 가 저장되지 않게 한다.
  if v_theme not in ('classic', 'snow', 'pink', 'night', 'postech', 'chalkboard') then
    return jsonb_build_object('ok', false, 'error', 'invalid_theme');
  end if;
  if v_department is not null and v_department not in (
    'mueunjae', 'math', 'phys', 'chem', 'life', 'mse', 'me', 'ime', 'ee', 'cse',
    'cheme', 'cite', 'semi', 'ai', 'grad', 'etc'
  ) then
    return jsonb_build_object('ok', false, 'error', 'invalid_department');
  end if;
  if v_description is not null and char_length(v_description) > 200 then
    return jsonb_build_object('ok', false, 'error', 'invalid_description');
  end if;
  if v_slug is not null and v_slug !~ '^[a-z0-9-]{4,40}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_slug');
  end if;

  -- 주소가 겹치면 앱이 새 주소로 다시 부를 수 있게 알려 준다 (사용자가 정한 주소면 앱이 그대로 안내)
  if v_slug is not null and exists (select 1 from public.trees t where t.slug = v_slug) then
    return jsonb_build_object('ok', false, 'error', 'slug_taken');
  end if;

  begin
    insert into public.trees
      (owner_id, slug, title, owner_name, theme, department, kind, description, is_open)
    values
      (auth.uid(),
       coalesce(v_slug, 'prof-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
       v_title, v_owner_name, v_theme, v_department, v_kind, v_description,
       false) -- 허락 대기
    returning id, slug into v_id, v_created_slug;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'slug_taken');
  end;

  return jsonb_build_object('ok', true, 'id', v_id, 'slug', v_created_slug);
end;
$$;

revoke all on function public.admin_create_special_tree(text, text, text, text, text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.admin_create_special_tree(text, text, text, text, text, text, text)
  to authenticated;

comment on function public.admin_create_special_tree(text, text, text, text, text, text, text)
  is '관리자: 교수님·특별 트리를 허락 대기(is_open = false)로 만든다 — spec.md 3장 · 4.6';

-- ---------- 3) list_professors(): 허락 대기 트리는 slug 를 숨긴다 (spec.md 4.6) ----------
-- "허락 대기 트리는 /professors 목록에만 보이고 링크가 없다" — 목록이 주소를 돌려주면
-- 화면 실수 한 번으로 닫힌 트리 링크가 새어 나간다. 열린 트리만 slug 를 준다.
-- 반환 타입(slug text)은 그대로라 create or replace 로 바꿀 수 있다 (권한도 유지된다).
create or replace function public.list_professors()
returns table (
  id uuid, slug text, owner_name text, department text,
  is_open boolean, like_count bigint, liked_by_me boolean
)
language sql stable security definer set search_path = public as $$
  select t.id,
         case when t.is_open then t.slug end, -- 허락 대기면 null
         t.owner_name, t.department, t.is_open,
         (select count(*) from public.professor_likes l where l.tree_id = t.id),
         coalesce((select true from public.professor_likes l
                    where l.tree_id = t.id and l.user_id = auth.uid()), false)
  from public.trees t
  where t.kind = 'professor'
  order by 6 desc, t.owner_name asc, t.created_at asc; -- 6 = like_count
$$;

revoke all on function public.list_professors() from public, anon, authenticated, service_role;
grant execute on function public.list_professors() to anon, authenticated, service_role;

comment on function public.list_professors() is '교수님 트리 목록 (관심순, 누가 눌렀는지는 제외, 허락 대기 트리는 slug 없음) — spec.md 4.6';

-- ---------- 4) admin_set_tree_open(): 특별·교수님 트리만 (spec.md 4.6) ----------
-- 일반 학생 트리까지 관리자가 닫고 열 수 있으면 "허락"이라는 뜻이 흐려지고,
-- 실수로 학생 트리를 닫으면 그 학생은 편지를 받지 못한다. 대상은 kind <> 'user' 로 한정한다.
create or replace function public.admin_set_tree_open(p_tree_id uuid, p_open boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_kind text;
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;

  select t.kind into v_kind from public.trees t where t.id = p_tree_id;
  if v_kind is null then
    raise exception 'not found';
  end if;
  if v_kind = 'user' then
    raise exception 'not a special tree';
  end if;

  update public.trees set is_open = coalesce(p_open, false) where id = p_tree_id;
end;
$$;

revoke all on function public.admin_set_tree_open(uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function public.admin_set_tree_open(uuid, boolean) to authenticated, service_role;

comment on function public.admin_set_tree_open(uuid, boolean)
  is '관리자: 교수님·특별 트리 허락 상태 바꾸기 (일반 트리는 대상 아님) — spec.md 4.6';

-- ---------- 5) 허락 대기 트리는 테이블에서도 주인·관리자만 (spec.md 4.6) ----------
-- 3)은 list_professors() 가 돌려주는 slug 만 숨겼다. 0001 의 trees SELECT 정책이 using (true) 라서
-- 공개 anon 키로 GET /rest/v1/trees?kind=eq.professor&is_open=eq.false&select=slug 를 부르면
-- 허락 대기 트리의 주소가 그대로 나왔다 (REST 는 함수가 아니라 테이블을 읽는다).
-- 행 제한은 RLS 가 한다: 일반 트리·열린 트리는 누구나, 닫힌 특별 트리는 주인과 관리자만.
-- list_professors()·admin_list_special_trees()·submit_letter()·get_letters_by_read_key() 는
-- security definer 라 이 정책과 무관하게 자기 규칙(허락 대기는 slug 없음·편지 거부)을 지킨다.
drop policy if exists "trees readable" on public.trees;
create policy "trees readable" on public.trees for select
  using (
    kind = 'user'
    or is_open
    or auth.uid() = owner_id
    or public.is_admin()
  );

comment on policy "trees readable" on public.trees
  is '일반 트리·열린 트리는 누구나, 허락 대기 특별 트리는 주인·관리자만 (spec.md 4.6)';

-- 수정한 0006 을 다시 실행할 때도 같은 정책이 남는다 (drop if exists → create).
-- 0006 의 SQL Editor 실행 결과에는 정책 목록을 함께 확인한다.
