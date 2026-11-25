import { notFound } from "next/navigation";
import WriteForm from "@/components/WriteForm";
import { demoMode, getOrnaments, getRevealAt, getTreeBySlug } from "@/lib/data";
import { getSeason, parseForcedDday } from "@/lib/season";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ slug: string }>; searchParams: Promise<{ dday?: string }> };

export default async function WritePage({ params, searchParams }: Params) {
  const { slug } = await params;
  const { dday } = await searchParams;
  const tree = await getTreeBySlug(slug);
  if (!tree) notFound();
  // 허락 대기 트리에는 편지를 쓸 수 없다 (spec.md 4.6): 주인·관리자는 주소로 트리를 볼 수 있지만
  // submit_letter() 는 닫힌 트리를 거부하므로, 작성 화면 자체를 없는 화면으로 보낸다.
  if (!tree.is_open) notFound();

  // 1단계 미리보기용: 트리 화면과 같은 장식·전구 단계 (spec.md 3장, C13). 편지 본문·고백 여부는 넘기지 않는다
  const [ornaments, revealAt] = await Promise.all([getOrnaments(tree.id), getRevealAt()]);
  // ?dday=N 은 연출 미리보기 전용 (트리 화면과 같은 규칙). 편지 권한과 무관
  const forced = parseForcedDday(dday, demoMode || process.env.NODE_ENV !== "production");
  const season = getSeason(Date.now(), revealAt, forced);

  return (
    <WriteForm
      tree={{ id: tree.id, slug: tree.slug, title: tree.title, owner_name: tree.owner_name, theme: tree.theme, kind: tree.kind, tree_color: tree.tree_color }}
      ornaments={ornaments.map((o) => ({ id: o.id, ornament_type: o.ornament_type, nickname: o.nickname }))}
      season={season}
    />
  );
}
