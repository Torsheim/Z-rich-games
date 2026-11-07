export const categories = {
  outdoors: "Outdoors",
  food: "Food & drink",
  sports: "Sports",
  culture: "Arts & culture",
  social: "Social",
  cityquest: "CityQuest",
  other: "Other",
} as const;

export type Category = keyof typeof categories;

export type User = {
  id: string;
  displayName: string;
};

export type CreateActivityInput = {
  title: string;
  category: Category;
  description: string;
  location: string;
  startsAt: string;
  maxParticipants: number;
};

export type Activity = CreateActivityInput & {
  id: string;
  participantCount: number;
  joined: boolean;
  isHost: boolean;
  cancelled: boolean;
  gameId: string | null;
};

export type ActivityDetail = Activity & {
  participants: User[];
};

export type GameStatus = "lobby" | "active" | "finished";

export type Team = {
  id: string;
  name: string;
  members: User[];
  score: number;
};

export type Challenge = {
  id: string;
  title: string;
  description: string;
  points: number;
  category: string;
  completed: boolean;
};

export type GameView = {
  id: string;
  activityId: string;
  title: string;
  joinCode: string;
  status: GameStatus;
  isHost: boolean;
  teams: Team[];
  teamId: string | null;
  challenges: Challenge[];
};
